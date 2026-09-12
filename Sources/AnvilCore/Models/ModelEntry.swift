import Foundation

/// Where a registered model's files came from.
public enum ModelSource: Codable, Sendable, Equatable {
    case huggingFace(repoID: String, revision: String)
    case imported(originalPath: String)
}

/// One model the app knows about — downloaded from Hugging Face or
/// imported from an existing folder on disk. `localPath` always points
/// at real files on disk; nothing is re-downloaded for an entry that
/// already resolves to files that exist.
public struct ModelEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public var source: ModelSource
    public var localPath: String
    public var sizeBytes: Int64?
    public var addedAt: Date
    public var kind: ModelKind
    /// Image models only. When true (the default), the model stays
    /// resident after a chat tool-call generation finishes. When false,
    /// `ChatViewModel` unloads it right after delivering the image to
    /// free its memory, and loads it again on demand the next time one
    /// is requested — slower per image, but nothing sits in memory
    /// between requests.
    public var keepImageModelLoadedInChat: Bool
    /// Image models only. Default generation resolution — nil falls
    /// back to `ImageGenerationSettings.default` (512×512).
    public var defaultImageWidth: Int?
    public var defaultImageHeight: Int?
    /// User override for the inference engine. If nil, auto-detected from file layout.
    public var engineOverride: InferenceEngine?

    /// Resolves the actual inference engine to use for this model.
    public var effectiveEngine: InferenceEngine {
        if let engineOverride { return engineOverride }
        let url = URL(fileURLWithPath: localPath)
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let lower = contents.map { $0.lowercased() }

        if kind == .image {
            if lower.contains(where: { $0.hasSuffix(".ckpt") || $0.hasSuffix(".nnc") })
                || localPath.lowercased().hasSuffix(".ckpt")
                || localPath.lowercased().contains("drawthings") {
                return .drawThings
            }
            return .mflux
        }

        // Inspect local path to see if it's GGUF or Safetensors/MLX
        if lower.contains(where: { $0.hasSuffix(".gguf") }) || localPath.lowercased().hasSuffix(".gguf") {
            return .llamaCpp
        }
        return .mlx
    }

    public init(
        id: String,
        displayName: String,
        source: ModelSource,
        localPath: String,
        sizeBytes: Int64?,
        addedAt: Date = Date(),
        kind: ModelKind = .text,
        keepImageModelLoadedInChat: Bool = true,
        defaultImageWidth: Int? = nil,
        defaultImageHeight: Int? = nil,
        engineOverride: InferenceEngine? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.localPath = localPath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.kind = kind
        self.keepImageModelLoadedInChat = keepImageModelLoadedInChat
        self.defaultImageWidth = defaultImageWidth
        self.defaultImageHeight = defaultImageHeight
        self.engineOverride = engineOverride
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, source, localPath, sizeBytes, addedAt, kind
        case keepImageModelLoadedInChat, defaultImageWidth, defaultImageHeight
        case engineOverride
    }

    // A registry saved before a field existed just defaults it on next
    // load — no migration step, no crash.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        source = try container.decode(ModelSource.self, forKey: .source)
        localPath = try container.decode(String.self, forKey: .localPath)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        kind = try container.decodeIfPresent(ModelKind.self, forKey: .kind) ?? .text
        keepImageModelLoadedInChat = try container.decodeIfPresent(Bool.self, forKey: .keepImageModelLoadedInChat) ?? true
        defaultImageWidth = try container.decodeIfPresent(Int.self, forKey: .defaultImageWidth)
        defaultImageHeight = try container.decodeIfPresent(Int.self, forKey: .defaultImageHeight)
        engineOverride = try container.decodeIfPresent(InferenceEngine.self, forKey: .engineOverride)
    }
}

/// Plain `.iso8601` truncates to whole seconds, which would make a
/// freshly-created entry compare unequal to itself after a save/reload
/// round trip. Fractional seconds keep that lossless.
private let anvilDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

public extension JSONEncoder {
    static var anvil: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(anvilDateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var anvil: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = anvilDateFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date, got \(text)"
                )
            }
            return date
        }
        return decoder
    }
}
