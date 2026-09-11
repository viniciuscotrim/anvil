import Foundation

/// One image the app generated — kept as a real file under
/// `images/` (not a database blob), with this record pointing at it.
///
/// `lineageID`/`versionNumber` are the Draw-Things-style "version
/// history" mechanism: generating again from an already-selected image
/// (whether only the prompt changed, or a different model was picked)
/// never overwrites it — it adds a new `GeneratedImage` sharing the
/// same `lineageID` with `versionNumber` one higher, so the original
/// and every iteration on it all stay browsable together. A fresh
/// generation (nothing selected first) starts its own lineage —
/// `lineageID` defaults to the image's own `id` when not given one to
/// continue, so every image is at minimum a singleton lineage of one.
public struct GeneratedImage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var lineageID: UUID
    public var versionNumber: Int
    public var prompt: String
    public var modelDisplayName: String
    public var localPath: String
    public var width: Int
    public var height: Int
    public var seed: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        lineageID: UUID? = nil,
        versionNumber: Int = 1,
        prompt: String,
        modelDisplayName: String,
        localPath: String,
        width: Int,
        height: Int,
        seed: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.lineageID = lineageID ?? id
        self.versionNumber = versionNumber
        self.prompt = prompt
        self.modelDisplayName = modelDisplayName
        self.localPath = localPath
        self.width = width
        self.height = height
        self.seed = seed
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, lineageID, versionNumber, prompt, modelDisplayName, localPath, width, height, seed, createdAt
    }

    // An image saved before lineages existed just becomes its own
    // singleton lineage (version 1) on next load — no migration step.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        lineageID = try container.decodeIfPresent(UUID.self, forKey: .lineageID) ?? id
        versionNumber = try container.decodeIfPresent(Int.self, forKey: .versionNumber) ?? 1
        prompt = try container.decode(String.self, forKey: .prompt)
        modelDisplayName = try container.decode(String.self, forKey: .modelDisplayName)
        localPath = try container.decode(String.self, forKey: .localPath)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        seed = try container.decode(Int.self, forKey: .seed)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// Persists the generated-image gallery to one JSON file — same
/// pattern as `ModelRegistry`/`ChatThreadStore`. Owned once and shared
/// (Chat and the Images tab both write through the same instance from
/// `AppState`), so — unlike `ModelRegistry`/`ChatProfileStore` — an
/// in-memory cache here is safe: there's only ever one reader/writer.
public actor GeneratedImageStore {
    private let fileURL: URL
    private var images: [GeneratedImage] = []
    private var loaded = false

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("registry.json")
    ) {
        self.fileURL = fileURL
    }

    /// Every image, newest first — used for the version-history
    /// carousel of one lineage; see `latestPerLineage()` for the main
    /// gallery grid, which should show one tile per lineage, not one
    /// per version.
    public func all() -> [GeneratedImage] {
        loadIfNeeded()
        return images.sorted { $0.createdAt > $1.createdAt }
    }

    /// Every version of one lineage, oldest first (version 1 → latest)
    /// — the order the history carousel walks through an iteration.
    public func versions(ofLineage lineageID: UUID) -> [GeneratedImage] {
        loadIfNeeded()
        return images.filter { $0.lineageID == lineageID }.sorted { $0.versionNumber < $1.versionNumber }
    }

    /// One entry per lineage — its latest version — newest-updated
    /// lineage first. What the main gallery grid shows.
    public func latestPerLineage() -> [GeneratedImage] {
        loadIfNeeded()
        var latestByLineage: [UUID: GeneratedImage] = [:]
        for image in images {
            if let existing = latestByLineage[image.lineageID], existing.versionNumber >= image.versionNumber {
                continue
            }
            latestByLineage[image.lineageID] = image
        }
        return latestByLineage.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// The version number a new image continuing this lineage should
    /// use — one past whatever's highest so far (1 if the lineage
    /// doesn't exist yet, which just means this becomes its first
    /// version).
    public func nextVersionNumber(forLineage lineageID: UUID) -> Int {
        loadIfNeeded()
        let highest = images.filter { $0.lineageID == lineageID }.map(\.versionNumber).max() ?? 0
        return highest + 1
    }

    @discardableResult
    public func add(_ image: GeneratedImage) throws -> GeneratedImage {
        loadIfNeeded()
        images.append(image)
        try persist()
        return image
    }

    /// Removes the record and deletes the underlying file — unlike a
    /// model or a thread, a generated image has no other reason to
    /// keep the file around once its entry is gone.
    public func delete(id: UUID) throws {
        loadIfNeeded()
        if let image = images.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(atPath: image.localPath)
        }
        images.removeAll { $0.id == id }
        try persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        images = (try? JSONDecoder.anvil.decode([GeneratedImage].self, from: data)) ?? []
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(images)
        try data.write(to: fileURL, options: .atomic)
    }
}
