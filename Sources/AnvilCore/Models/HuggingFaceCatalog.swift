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
    /// The repo's own file list (`siblings`), when the search request
    /// asked for it — powers `compatibility` below. Not persisted
    /// anywhere; only ever a live search result.
    public let filePaths: [String]?
    /// The repo's last-pushed-to date, straight from Hugging Face's own
    /// `lastModified` field — powers Search's "Updated" sort option
    /// (`ModelSearchSortOption`). `nil` only if the API response itself
    /// didn't carry the field (shouldn't happen given `expand=
    /// lastModified` below, but never assumed).
    public let lastModified: Date?

    /// Whether this repo's file layout looks loadable by Anvil's image
    /// backend — see `ModelCompatibility`'s own doc comment for the
    /// real bug this exists to catch before a multi-gigabyte download,
    /// not after. `.unknown` when `filePaths` wasn't requested.
    public var compatibility: ModelCompatibility {
        guard let filePaths else { return .unknown }
        return ModelCompatibility.classify(paths: filePaths)
    }

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case downloads
        case likes
        case tags
        case safetensors
        case siblings
        case lastModified
    }

    private struct SafetensorsField: Decodable {
        let parameters: [String: Int64]?
    }

    private struct SiblingField: Decodable {
        let rfilename: String
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

        let siblings = try container.decodeIfPresent([SiblingField].self, forKey: .siblings)
        filePaths = siblings?.map(\.rfilename)

        let lastModifiedString = try container.decodeIfPresent(String.self, forKey: .lastModified)
        lastModified = lastModifiedString.flatMap(Self.parseHFDate)
    }

    public init(
        modelID: String,
        downloads: Int?,
        likes: Int?,
        tags: [String]?,
        sizeBytes: Int64?,
        filePaths: [String]? = nil,
        lastModified: Date? = nil
    ) {
        self.modelID = modelID
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.sizeBytes = sizeBytes
        self.filePaths = filePaths
        self.lastModified = lastModified
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(downloads, forKey: .downloads)
        try container.encodeIfPresent(likes, forKey: .likes)
        try container.encodeIfPresent(tags, forKey: .tags)
    }

    // Hugging Face's `lastModified` carries fractional seconds
    // ("2025-06-27T16:22:19.000Z"); a plain `ISO8601DateFormatter`
    // rejects that unless `.withFractionalSeconds` is set. Falls back
    // to the plain format too, just in case a response ever omits them.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static func parseHFDate(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Plain.date(from: string)
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
            URLQueryItem(name: "expand", value: "safetensors"),
            // Powers `HFModelSummary.compatibility` — the repo's own
            // file list is enough to tell a proper pipeline apart from
            // a raw single-file checkpoint before ever downloading it.
            URLQueryItem(name: "expand", value: "siblings"),
            // Powers Search's "Updated" sort option.
            URLQueryItem(name: "expand", value: "lastModified")
        ]
        guard let url = components.url else {
            throw ModelError.searchFailed("Could not build search URL")
        }

        var request = URLRequest(url: url)
        // Authenticated when a token is set (Anvil's Settings) — turns
        // up the user's own private/gated repos in search results too,
        // not just public ones, and gets Hugging Face's higher
        // authenticated rate limit.
        if let token = HFTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.searchFailed("Unexpected response from Hugging Face")
        }

        do {
            return try JSONDecoder().decode([HFModelSummary].self, from: data)
        } catch {
            throw ModelError.searchFailed("Could not parse Hugging Face response: \(error.localizedDescription)")
        }
    }

    /// Looks up one exact repo by id — for callers that already know
    /// which model they want (e.g. one typed directly into a model-ID
    /// field) rather than searching, and need its real file list to
    /// download it. Hits `/api/models/{id}` instead of the search
    /// endpoint's `/api/models?search=`, which can't guarantee an exact
    /// match is even the top result.
    public func modelInfo(id: String) async throws -> HFModelSummary {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "expand", value: "downloads"),
            URLQueryItem(name: "expand", value: "likes"),
            URLQueryItem(name: "expand", value: "tags"),
            URLQueryItem(name: "expand", value: "safetensors"),
            URLQueryItem(name: "expand", value: "siblings"),
            URLQueryItem(name: "expand", value: "lastModified")
        ]
        guard let url = components.url else {
            throw ModelError.searchFailed("Could not build model URL for '\(id)'")
        }

        var request = URLRequest(url: url)
        if let token = HFTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.searchFailed("Model '\(id)' was not found on Hugging Face")
        }

        do {
            return try JSONDecoder().decode(HFModelSummary.self, from: data)
        } catch {
            throw ModelError.searchFailed("Could not parse Hugging Face response: \(error.localizedDescription)")
        }
    }

    /// Per-file sizes for one repo — `search`/`modelInfo`'s `expand=
    /// siblings` only ever returns each file's *name*
    /// (`HFModelSummary.filePaths`), never its size, so a repo with
    /// several GGUF quantizations (a real, common shape — one repo,
    /// ten-plus multi-gigabyte files) can't be told apart by size from
    /// that response alone. The repo tree endpoint
    /// (`/api/models/{id}/tree/{revision}`) does report one, so callers
    /// that actually need to show or choose among individual files
    /// (`GGUFFilePickerView`) hit this instead — kept as its own call
    /// rather than folded into `modelInfo`, since most callers never
    /// need per-file sizes and a search result listing dozens of
    /// repos shouldn't pay for one more request each just in case.
    public func fileTree(repoID: String, revision: String = "main") async throws -> [HFRepoFile] {
        guard let encodedRevision = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(encodedRevision)") else {
            throw ModelError.searchFailed("Could not build tree URL for '\(repoID)'")
        }

        var request = URLRequest(url: url)
        if let token = HFTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.searchFailed("Could not list files for '\(repoID)'")
        }

        struct TreeEntry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }
        do {
            let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
            return entries.filter { $0.type == "file" }.map { HFRepoFile(path: $0.path, sizeBytes: $0.size) }
        } catch {
            throw ModelError.searchFailed("Could not parse Hugging Face file list: \(error.localizedDescription)")
        }
    }
}

/// One file in a Hugging Face repo, with its real size — see
/// `HuggingFaceCatalog.fileTree`'s own doc comment for why this is a
/// separate call from the search/lookup ones (`HFModelSummary.filePaths`
/// carries the same repos' file *names* without sizes).
public struct HFRepoFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64?

    public init(path: String, sizeBytes: Int64?) {
        self.path = path
        self.sizeBytes = sizeBytes
    }
}
