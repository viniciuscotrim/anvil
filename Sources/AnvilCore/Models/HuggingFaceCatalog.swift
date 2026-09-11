import Foundation

/// Lightweight result from Hugging Face's model search — enough to show
/// a result list and start a download. No auth needed; this hits the
/// public `huggingface.co/api/models` endpoint directly rather than
/// shelling out to Python, so search stays fast and doesn't need the
/// Python environment to be ready yet.
public struct HFModelSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { modelID }
    public let modelID: String
    public let downloads: Int?
    public let likes: Int?
    public let tags: [String]?
    /// Estimated on-disk size from the repo's safetensors parameter
    /// counts (`sum(params * bytesPerDtype)`) — an estimate, not an
    /// exact byte count (actual file sizes include headers/padding and
    /// a repo can mix formats), but close enough to sort a search
    /// result into Small/Medium/Large. `nil` for repos with no
    /// safetensors metadata at all (e.g. GGUF-only repos).
    public let sizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case downloads
        case likes
        case tags
        case safetensors
    }

    private struct SafetensorsField: Decodable {
        let parameters: [String: Int64]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try container.decodeIfPresent(Int.self, forKey: .likes)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)

        let safetensors = try container.decodeIfPresent(SafetensorsField.self, forKey: .safetensors)
        if let parameters = safetensors?.parameters {
            sizeBytes = parameters.reduce(into: Int64(0)) { total, entry in
                total += entry.value * Self.bytesPerParameter(dtype: entry.key)
            }
        } else {
            sizeBytes = nil
        }
    }

    public init(modelID: String, downloads: Int?, likes: Int?, tags: [String]?, sizeBytes: Int64?) {
        self.modelID = modelID
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.sizeBytes = sizeBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(downloads, forKey: .downloads)
        try container.encodeIfPresent(likes, forKey: .likes)
        try container.encodeIfPresent(tags, forKey: .tags)
    }

    private static func bytesPerParameter(dtype: String) -> Int64 {
        switch dtype.uppercased() {
        case "F64", "I64", "U64": return 8
        case "F32", "I32", "U32": return 4
        case "F16", "BF16", "I16", "U16": return 2
        case "I8", "U8", "F8_E4M3", "F8_E5M2", "BOOL": return 1
        default: return 2 // most current models are fp16/bf16 by default
        }
    }
}

public struct HuggingFaceCatalog: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, limit: Int = 20) async throws -> [HFModelSummary] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            // Explicit `expand` — using it at all replaces the default
            // field set, so every field this type reads has to be
            // listed here, not just the new one (safetensors).
            URLQueryItem(name: "expand", value: "downloads"),
            URLQueryItem(name: "expand", value: "likes"),
            URLQueryItem(name: "expand", value: "tags"),
            URLQueryItem(name: "expand", value: "safetensors")
        ]
        guard let url = components.url else {
            throw ModelError.searchFailed("Could not build search URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.searchFailed("Unexpected response from Hugging Face")
        }

        do {
            return try JSONDecoder().decode([HFModelSummary].self, from: data)
        } catch {
            throw ModelError.searchFailed("Could not parse Hugging Face response: \(error.localizedDescription)")
        }
    }
}
