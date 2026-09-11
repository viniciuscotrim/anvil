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

    public init(
        id: String,
        displayName: String,
        source: ModelSource,
        localPath: String,
        sizeBytes: Int64?,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.localPath = localPath
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
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
