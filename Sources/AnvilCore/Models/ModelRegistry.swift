import Foundation

/// The single source of truth for "models this app knows about" — backed
/// by one JSON file so it's trivially inspectable (`cat registry.json`)
/// for gate verification, not just visible in the UI. An actor because
/// both the UI and any background download/import work touch it.
///
/// Always re-reads the file rather than trusting an in-memory cache —
/// more than one `ModelRegistry` instance can exist at once (the model
/// manager and chat each hold their own), and a stale cache in one
/// would mean it never sees a model downloaded/imported through the
/// other, and — worse — a write from a stale instance could silently
/// drop entries the other one had already saved. The file is tiny and
/// reads are infrequent, so the cost of always re-reading is negligible
/// next to that correctness gap.
public actor ModelRegistry {
    private let fileURL: URL

    public init(fileURL: URL = RuntimePaths.modelsDirectory.appendingPathComponent("registry.json")) {
        self.fileURL = fileURL
    }

    public func all() async -> [ModelEntry] {
        load().sorted { $0.addedAt < $1.addedAt }
    }

    public func contains(id: String) async -> Bool {
        load().contains { $0.id == id }
    }

    @discardableResult
    public func upsert(_ entry: ModelEntry) throws -> ModelEntry {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist(entries)
        return entry
    }

    public func remove(id: String) throws {
        var entries = load()
        entries.removeAll { $0.id == id }
        try persist(entries)
    }

    /// Merges entries that point at the same `localPath` under
    /// different ids — a real, reported bug: the same model ended up
    /// registered twice, once under a stable Hugging-Face-repo id from
    /// being downloaded through search, once under a second,
    /// path-derived "imported:" id from a later models-folder scan
    /// sweeping up the very same files (fixed at the source in
    /// `ModelImporter.importFolder`, but this repairs a registry that
    /// already has a duplicate in it from before that fix). Keeps one
    /// entry per real `localPath` — a Hugging-Face-sourced one over an
    /// imported one, since its id doesn't depend on where the files
    /// happen to sit, and the earliest `addedAt` if that doesn't decide
    /// it either. Safe to call any time; a no-op when nothing needs
    /// merging. Called automatically whenever the Models tab loads the
    /// registry, so an existing duplicate self-heals the next time the
    /// app is used rather than needing a manual fix.
    @discardableResult
    public func deduplicateByLocalPath() throws -> Int {
        let entries = load()
        var byPath: [String: ModelEntry] = [:]
        var pathOrder: [String] = []
        for entry in entries {
            let key = URL(fileURLWithPath: entry.localPath).canonicalModelPathKey
            if let existing = byPath[key] {
                byPath[key] = Self.preferred(existing, entry)
            } else {
                byPath[key] = entry
                pathOrder.append(key)
            }
        }
        let deduped = pathOrder.compactMap { byPath[$0] }
        let removedCount = entries.count - deduped.count
        if removedCount > 0 {
            try persist(deduped)
        }
        return removedCount
    }

    /// Re-detects `kind` for every entry against its real files and
    /// updates any that changed — self-heals an entry registered under
    /// an older, less accurate `ModelKindDetector` (the real case this
    /// exists for: `black-forest-labs/FLUX.2-klein-4b-nvfp4`, a flat
    /// single-safetensors-file repo the original structural-only check
    /// always called `.text`, wrongly hiding its image-model chat
    /// settings). Only touches entries whose detected kind actually
    /// changed; leaves `sizeBytes` and everything else alone. Called
    /// automatically whenever the Models tab loads the registry.
    @discardableResult
    public func refreshKinds() throws -> Int {
        var entries = load()
        var changedCount = 0
        for index in entries.indices {
            let detected = ModelKindDetector.detect(at: URL(fileURLWithPath: entries[index].localPath))
            if detected != entries[index].kind {
                entries[index].kind = detected
                changedCount += 1
            }
        }
        if changedCount > 0 {
            try persist(entries)
        }
        return changedCount
    }

    private static func preferred(_ a: ModelEntry, _ b: ModelEntry) -> ModelEntry {
        func isHuggingFaceSourced(_ entry: ModelEntry) -> Bool {
            if case .huggingFace = entry.source { return true }
            return false
        }
        if isHuggingFaceSourced(a) != isHuggingFaceSourced(b) {
            return isHuggingFaceSourced(a) ? a : b
        }
        return a.addedAt <= b.addedAt ? a : b
    }

    private func load() -> [ModelEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ModelEntry].self, from: data)) ?? []
    }

    private func persist(_ entries: [ModelEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
