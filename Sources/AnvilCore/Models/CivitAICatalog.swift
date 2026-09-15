import Foundation

/// One searchable CivitAI model — enough to show a result and start a
/// download. Resolves straight to its first version's primary
/// downloadable file (almost always the one real checkpoint file;
/// CivitAI's own UI defaults to the same), since that's what Anvil
/// actually needs to register and load — not the full version/file
/// tree CivitAI's API otherwise exposes.
public struct CivitAIModelSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    /// "Checkpoint", "LORA", "TextualInversion", … — Anvil only makes
    /// real use of "Checkpoint" today (a whole model to load), but
    /// keeps whatever CivitAI reports for display/filtering.
    public let type: String
    /// e.g. "Flux.1 D", "SDXL 1.0", "SD 1.5", "Pony" — CivitAI's own
    /// architecture label, a much more reliable compatibility signal
    /// than guessing from a file layout: a "Flux.1"-family checkpoint
    /// is at least architecturally the kind of thing `mflux` knows how
    /// to run; an SD1.5/SDXL/Pony one currently isn't (see
    /// `ModelCompatibility` for the equivalent Hugging Face check).
    public let baseModel: String?
    public let nsfw: Bool
    public let downloadCount: Int?
    public let creatorUsername: String?
    public let primaryFile: PrimaryFile?
    /// The first (current) model version's own `publishedAt` — the
    /// only update/publish timestamp CivitAI's search response actually
    /// carries (no separate `updatedAt` at either the model or version
    /// level). Powers Search's "Updated" sort option.
    public let publishedAt: Date?

    public struct PrimaryFile: Codable, Sendable, Equatable {
        public let downloadURL: URL
        public let filename: String
        public let sizeBytes: Int64?
        /// "SafeTensor", "PickleTensor", "Other", … — Anvil only
        /// downloads/registers "SafeTensor" files; anything else has
        /// no `primaryFile` at all (see the decoder below), same as a
        /// version with no files.
        public let format: String?
    }

    /// Whether Anvil's current image backend (`mflux`, Flux-only) has
    /// any real chance of loading this — `baseModel` naming a
    /// Flux-family architecture. Everything else (SDXL, SD 1.5, Pony,
    /// Illustrious, …) is `false` today; see the CivitAI section of the
    /// README for the SD/SDXL backend that would change that.
    public var isFluxFamily: Bool {
        guard let baseModel else { return false }
        return baseModel.lowercased().contains("flux")
    }

    public init(
        id: Int,
        name: String,
        type: String,
        baseModel: String?,
        nsfw: Bool,
        downloadCount: Int?,
        creatorUsername: String?,
        primaryFile: PrimaryFile?,
        publishedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseModel = baseModel
        self.nsfw = nsfw
        self.downloadCount = downloadCount
        self.creatorUsername = creatorUsername
        self.primaryFile = primaryFile
        self.publishedAt = publishedAt
    }

    // MARK: - Decoding CivitAI's real (nested, nullable-heavy) shape

    private enum CodingKeys: String, CodingKey {
        case id, name, type, nsfw, stats, creator, modelVersions
    }
    private struct Stats: Decodable { let downloadCount: Int? }
    private struct Creator: Decodable { let username: String? }
    private struct ModelVersion: Decodable {
        let baseModel: String?
        let files: [File]?
        let publishedAt: String?
    }
    private struct File: Decodable {
        let name: String
        let sizeKB: Double?
        let type: String?
        let primary: Bool?
        let downloadUrl: String?
        let metadata: Metadata?
        struct Metadata: Decodable { let format: String? }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        nsfw = try container.decodeIfPresent(Bool.self, forKey: .nsfw) ?? false
        downloadCount = try container.decodeIfPresent(Stats.self, forKey: .stats)?.downloadCount
        creatorUsername = try container.decodeIfPresent(Creator.self, forKey: .creator)?.username

        let versions = try container.decodeIfPresent([ModelVersion].self, forKey: .modelVersions) ?? []
        let firstVersion = versions.first
        baseModel = firstVersion?.baseModel
        publishedAt = firstVersion?.publishedAt.flatMap(Self.parseCivitAIDate)

        let files = firstVersion?.files ?? []
        // The version's own flagged primary file, or its first
        // safetensors-formatted one — CivitAI usually flags exactly
        // one file `primary: true`, but not always.
        let chosen = files.first { $0.primary == true && $0.metadata?.format == "SafeTensor" }
            ?? files.first { $0.metadata?.format == "SafeTensor" }
        if let chosen, let urlString = chosen.downloadUrl, let url = URL(string: urlString) {
            primaryFile = PrimaryFile(
                downloadURL: url,
                filename: chosen.name,
                sizeBytes: chosen.sizeKB.map { Int64($0 * 1024) },
                format: chosen.metadata?.format
            )
        } else {
            primaryFile = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(nsfw, forKey: .nsfw)
    }

    // CivitAI's `publishedAt` carries fractional seconds
    // ("2024-08-02T23:46:31.363Z"), same shape as Hugging Face's own
    // `lastModified` — see that type's identical formatter pair.
    private static func parseCivitAIDate(_ string: String) -> Date? {
        Date.parseFlexibleISO8601(string)
    }
}

/// Searches CivitAI's public REST API directly — no Python needed, same
/// shape of client as `HuggingFaceCatalog`.
public struct CivitAICatalog: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(query: String, limit: Int = 20, checkpointsOnly: Bool = true) async throws -> [CivitAIModelSummary] {
        var components = URLComponents(string: "https://civitai.com/api/v1/models")!
        var queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "Most Downloaded")
        ]
        if checkpointsOnly {
            queryItems.append(URLQueryItem(name: "types", value: "Checkpoint"))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ModelError.searchFailed("Could not build CivitAI search URL")
        }

        var request = URLRequest(url: url)
        if let token = CivitAITokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelError.searchFailed("Unexpected response from CivitAI")
        }

        struct SearchResponse: Decodable { let items: [CivitAIModelSummary] }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).items
        } catch {
            throw ModelError.searchFailed("Could not parse CivitAI response: \(error.localizedDescription)")
        }
    }
}
