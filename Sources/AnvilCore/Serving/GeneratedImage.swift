import Foundation

/// One image the app generated — kept as a real file under
/// `images/` (not a database blob), with this record pointing at it.
public struct GeneratedImage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var prompt: String
    public var modelDisplayName: String
    public var localPath: String
    public var width: Int
    public var height: Int
    public var seed: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        prompt: String,
        modelDisplayName: String,
        localPath: String,
        width: Int,
        height: Int,
        seed: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.modelDisplayName = modelDisplayName
        self.localPath = localPath
        self.width = width
        self.height = height
        self.seed = seed
        self.createdAt = createdAt
    }
}

/// Persists the generated-image gallery to one JSON file — same
/// pattern as `ModelRegistry`/`ChatThreadStore`.
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

    /// Newest first.
    public func all() -> [GeneratedImage] {
        loadIfNeeded()
        return images.sorted { $0.createdAt > $1.createdAt }
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
