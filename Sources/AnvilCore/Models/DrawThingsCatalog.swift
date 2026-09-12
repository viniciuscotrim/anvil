import Foundation

/// One model from the official Draw Things community repository / catalog.
/// Represents official quantized checkpoints (Flux, SDXL, SD 1.5 in 8-bit, 4-bit, 3-bit, 2-bit).
public struct DrawThingsModelSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let repoID: String
    public let baseModel: String?
    public let quantization: String?
    public let downloads: Int?
    public let likes: Int?
    public let sizeBytes: Int64?
    public let filePaths: [String]?

    public init(
        id: String,
        name: String,
        repoID: String,
        baseModel: String? = nil,
        quantization: String? = nil,
        downloads: Int? = nil,
        likes: Int? = nil,
        sizeBytes: Int64? = nil,
        filePaths: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.repoID = repoID
        self.baseModel = baseModel
        self.quantization = quantization
        self.downloads = downloads
        self.likes = likes
        self.sizeBytes = sizeBytes
        self.filePaths = filePaths
    }
}

/// Catalog for browsing and searching official Draw Things models on Hugging Face (author: `drawthingsai`).
public struct DrawThingsCatalog: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Curated list of official Draw Things flagship models.
    public static let curatedModels: [DrawThingsModelSummary] = [
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-schnell",
            name: "FLUX.1 Schnell (8-bit / 4-bit / 3-bit / 2-bit)",
            repoID: "drawthingsai/FLUX.1-schnell",
            baseModel: "Flux.1",
            quantization: "8-bit / 4-bit / 3-bit",
            downloads: 48500,
            likes: 850,
            sizeBytes: 6_400_000_000,
            filePaths: ["model.ckpt", "model_index.json"]
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-dev",
            name: "FLUX.1 Dev (8-bit / 4-bit / 3-bit / 2-bit)",
            repoID: "drawthingsai/FLUX.1-dev",
            baseModel: "Flux.1",
            quantization: "8-bit / 4-bit / 3-bit",
            downloads: 32000,
            likes: 620,
            sizeBytes: 6_400_000_000,
            filePaths: ["model.ckpt", "model_index.json"]
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Generic-SDXL-v1.0",
            name: "Generic SDXL v1.0 (8-bit / 4-bit)",
            repoID: "drawthingsai/Generic-SDXL-v1.0",
            baseModel: "SDXL",
            quantization: "8-bit / 4-bit",
            downloads: 24500,
            likes: 410,
            sizeBytes: 3_200_000_000,
            filePaths: ["model.ckpt"]
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Realistic-Vision-v6.0-B1",
            name: "Realistic Vision v6.0 (SD 1.5 Quantized)",
            repoID: "drawthingsai/Realistic-Vision-v6.0-B1",
            baseModel: "SD 1.5",
            quantization: "8-bit / 4-bit",
            downloads: 19800,
            likes: 380,
            sizeBytes: 1_800_000_000,
            filePaths: ["model.ckpt"]
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/DreamShaper-XL-v2.1",
            name: "DreamShaper XL v2.1 (SDXL 8-bit / 4-bit)",
            repoID: "drawthingsai/DreamShaper-XL-v2.1",
            baseModel: "SDXL",
            quantization: "8-bit / 4-bit",
            downloads: 15400,
            likes: 290,
            sizeBytes: 3_400_000_000,
            filePaths: ["model.ckpt"]
        )
    ]

    /// Searches official Draw Things repository models via Hugging Face API (`author: drawthingsai` or query match).
    public func search(query: String, limit: Int = 20) async throws -> [DrawThingsModelSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Self.curatedModels
        }

        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "drawthings \(trimmed)"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "expand", value: "downloads"),
            URLQueryItem(name: "expand", value: "likes"),
            URLQueryItem(name: "expand", value: "tags"),
            URLQueryItem(name: "expand", value: "safetensors"),
            URLQueryItem(name: "expand", value: "siblings")
        ]

        guard let url = components.url else { return Self.curatedModels }
        var request = URLRequest(url: url)
        if let token = HFTokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return Self.curatedModels.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }

        let hfSummaries = (try? JSONDecoder().decode([HFModelSummary].self, from: data)) ?? []
        var results: [DrawThingsModelSummary] = hfSummaries.map { hf in
            let base = extractBaseModel(from: hf.modelID, tags: hf.tags)
            let quant = extractQuantization(from: hf.modelID, tags: hf.tags)
            return DrawThingsModelSummary(
                id: "drawthings:\(hf.modelID)",
                name: formatDisplayName(repoID: hf.modelID),
                repoID: hf.modelID,
                baseModel: base,
                quantization: quant,
                downloads: hf.downloads,
                likes: hf.likes,
                sizeBytes: hf.sizeBytes,
                filePaths: hf.filePaths
            )
        }

        // Merge curated models matching the query if not already present
        for curated in Self.curatedModels where curated.name.localizedCaseInsensitiveContains(trimmed) || curated.repoID.localizedCaseInsensitiveContains(trimmed) {
            if !results.contains(where: { $0.repoID == curated.repoID }) {
                results.insert(curated, at: 0)
            }
        }

        return results.isEmpty ? Self.curatedModels : results
    }

    private func formatDisplayName(repoID: String) -> String {
        let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private func extractBaseModel(from repoID: String, tags: [String]?) -> String? {
        let lower = (repoID + " " + (tags?.joined(separator: " ") ?? "")).lowercased()
        if lower.contains("flux") { return "Flux.1" }
        if lower.contains("sdxl") { return "SDXL" }
        if lower.contains("sd1.5") || lower.contains("sd-1.5") || lower.contains("v1-5") { return "SD 1.5" }
        if lower.contains("sd3") { return "SD 3" }
        if lower.contains("pony") { return "Pony" }
        return nil
    }

    private func extractQuantization(from repoID: String, tags: [String]?) -> String? {
        let lower = (repoID + " " + (tags?.joined(separator: " ") ?? "")).lowercased()
        if lower.contains("8bit") || lower.contains("8-bit") || lower.contains("q8") { return "8-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") || lower.contains("q4") { return "4-bit" }
        if lower.contains("3bit") || lower.contains("3-bit") || lower.contains("q3") { return "3-bit" }
        if lower.contains("2bit") || lower.contains("2-bit") || lower.contains("q2") { return "2-bit" }
        return "Quantized"
    }
}
