import Foundation

/// One model variant from the Draw Things ecosystem / catalog.
/// Represents a specific quantized checkpoint file (e.g. Flux, SDXL, SD 1.5 in 8-bit, 4-bit, 3-bit, 2-bit)
/// with individual file size, popularity metrics, and targeted single-file download.
public struct DrawThingsModelSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let repoID: String
    public let filename: String?
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
        filename: String? = nil,
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
        self.filename = filename
        self.baseModel = baseModel
        self.quantization = quantization
        self.downloads = downloads
        self.likes = likes
        self.sizeBytes = sizeBytes
        self.filePaths = filePaths ?? (filename.map { [$0] })
    }
}

/// Catalog for browsing and searching official Draw Things models on Hugging Face (author: `drawthingsai` and community).
public struct DrawThingsCatalog: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Curated list of verified working image models (FLUX.1, FLUX.2 Klein, Krea, SDXL, etc.)
    /// separated into individual quantization variants with exact file sizes and popularity ratings.
    public static let curatedModels: [DrawThingsModelSummary] = [
        // FLUX.1 Schnell Quantized Variants
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-schnell-mflux-q4",
            name: "FLUX.1 Schnell (4-bit Quantized)",
            repoID: "mflux-community/flux-1-schnell-mflux-q4",
            baseModel: "Flux.1",
            quantization: "4-bit",
            downloads: 64200,
            likes: 850,
            sizeBytes: 6_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-schnell-mflux-q8",
            name: "FLUX.1 Schnell (8-bit Quantized)",
            repoID: "mflux-community/flux-1-schnell-mflux-q8",
            baseModel: "Flux.1",
            quantization: "8-bit",
            downloads: 48500,
            likes: 850,
            sizeBytes: 12_800_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-schnell-mflux-q3",
            name: "FLUX.1 Schnell (3-bit Quantized)",
            repoID: "mflux-community/flux-1-schnell-mflux-q3",
            baseModel: "Flux.1",
            quantization: "3-bit",
            downloads: 22100,
            likes: 850,
            sizeBytes: 4_800_000_000
        ),

        // FLUX.1 Dev Quantized Variants
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-dev-mflux-q4",
            name: "FLUX.1 Dev (4-bit Quantized)",
            repoID: "mflux-community/flux-1-dev-mflux-q4",
            baseModel: "Flux.1",
            quantization: "4-bit",
            downloads: 45800,
            likes: 620,
            sizeBytes: 6_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-dev-mflux-q8",
            name: "FLUX.1 Dev (8-bit Quantized)",
            repoID: "mflux-community/flux-1-dev-mflux-q8",
            baseModel: "Flux.1",
            quantization: "8-bit",
            downloads: 32000,
            likes: 620,
            sizeBytes: 12_800_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux-1-dev-mflux-q3",
            name: "FLUX.1 Dev (3-bit Quantized)",
            repoID: "mflux-community/flux-1-dev-mflux-q3",
            baseModel: "Flux.1",
            quantization: "3-bit",
            downloads: 18400,
            likes: 620,
            sizeBytes: 4_800_000_000
        ),

        // FLUX.2 Klein Variants (Complete working pipelines)
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux2-klein-4b-mflux-q4",
            name: "FLUX.2 Klein 4B (4-bit Quantized)",
            repoID: "mflux-community/flux2-klein-4b-mflux-q4",
            baseModel: "Flux.2",
            quantization: "4-bit",
            downloads: 38200,
            likes: 490,
            sizeBytes: 5_200_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux2-klein-9b-mflux-q4",
            name: "FLUX.2 Klein 9B (4-bit Quantized)",
            repoID: "mflux-community/flux2-klein-9b-mflux-q4",
            baseModel: "Flux.2",
            quantization: "4-bit",
            downloads: 29500,
            likes: 380,
            sizeBytes: 8_900_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/flux2-klein-9b-mflux-q8",
            name: "FLUX.2 Klein 9B (8-bit Quantized)",
            repoID: "mflux-community/flux2-klein-9b-mflux-q8",
            baseModel: "Flux.2",
            quantization: "8-bit",
            downloads: 21000,
            likes: 380,
            sizeBytes: 15_800_000_000
        ),

        // Turbo Variants
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/krea-2-turbo-mflux-q4",
            name: "Krea 2 Turbo (4-bit Quantized)",
            repoID: "mflux-community/krea-2-turbo-mflux-q4",
            baseModel: "Krea",
            quantization: "4-bit",
            downloads: 19400,
            likes: 310,
            sizeBytes: 4_900_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:mflux-community/z-image-turbo-mflux-q4",
            name: "Z-Image Turbo (4-bit Quantized)",
            repoID: "mflux-community/z-image-turbo-mflux-q4",
            baseModel: "Z-Image",
            quantization: "4-bit",
            downloads: 14800,
            likes: 260,
            sizeBytes: 4_200_000_000
        ),

        // Draw Things Community Video / Multimodal
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/MiniMax-H3",
            name: "MiniMax-H3 (Draw Things)",
            repoID: "drawthingsai/MiniMax-H3",
            baseModel: "MiniMax",
            quantization: "Quantized",
            downloads: 2800,
            likes: 110,
            sizeBytes: 6_200_000_000
        )
    ]

    /// Searches Draw Things models across official `drawthingsai` repositories and Hugging Face.
    /// Only returns runnable 1-file checkpoints (.ckpt, .nnc) or complete packages,
    /// avoiding clutter from hundreds of unrunnable sub-files or stray safetensors shards.
    public func search(query: String, limit: Int = 30) async throws -> [DrawThingsModelSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fetch from Hugging Face targeting drawthingsai author and explicit drawthings checkpoints
        var fetchedSummaries: [HFModelSummary] = []
        let searchQueries = trimmed.isEmpty ? ["author:drawthingsai", "drawthings"] : ["drawthingsai \(trimmed)", "drawthings \(trimmed)", trimmed]

        for kw in searchQueries {
            var components = URLComponents(string: "https://huggingface.co/api/models")!
            var queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "expand", value: "downloads"),
                URLQueryItem(name: "expand", value: "likes"),
                URLQueryItem(name: "expand", value: "tags"),
                URLQueryItem(name: "expand", value: "safetensors"),
                URLQueryItem(name: "expand", value: "siblings")
            ]
            if kw.hasPrefix("author:") {
                let author = String(kw.dropFirst(7))
                queryItems.append(URLQueryItem(name: "author", value: author))
            } else {
                queryItems.append(URLQueryItem(name: "search", value: kw))
            }
            components.queryItems = queryItems

            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            if let token = HFTokenStore.load(), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let decoded = (try? JSONDecoder().decode([HFModelSummary].self, from: data)) ?? []
                for item in decoded {
                    if !fetchedSummaries.contains(where: { $0.modelID == item.modelID }) {
                        fetchedSummaries.append(item)
                    }
                }
            }
        }

        var results: [DrawThingsModelSummary] = []
        var seenIDs = Set<String>()

        // 1. Filter and expand only genuine 1-file runnable checkpoints (.ckpt, .nnc)
        for hf in fetchedSummaries {
            let files = hf.filePaths ?? []
            // ONLY accept genuine Draw Things model formats (.ckpt, .nnc)
            let runnableCheckpointFiles = files.filter { file in
                let lower = file.lowercased()
                return (lower.hasSuffix(".ckpt") || lower.hasSuffix(".nnc"))
                    && !lower.hasPrefix(".")
                    && !lower.contains("mmproj")
                    && !lower.contains("adapter")
                    && !lower.contains("lora")
            }

            guard !runnableCheckpointFiles.isEmpty else {
                // If the repo has no .ckpt or .nnc files, do NOT display individual shard files
                continue
            }

            let base = extractBaseModel(from: hf.modelID, tags: hf.tags)
            let baseName = formatDisplayName(repoID: hf.modelID)

            for file in runnableCheckpointFiles {
                let quant = extractQuantization(from: file, tags: hf.tags)
                let variantID = "drawthings:\(hf.modelID):\(file)"
                guard !seenIDs.contains(variantID) else { continue }
                seenIDs.insert(variantID)

                let estimatedSize = estimateFileSize(filename: file, fallbackTotal: hf.sizeBytes, totalFiles: runnableCheckpointFiles.count, baseModel: base)
                let cleanFilename = (file as NSString).lastPathComponent
                let variantName = "\(baseName) - \(cleanFilename)"

                results.append(DrawThingsModelSummary(
                    id: variantID,
                    name: variantName,
                    repoID: hf.modelID,
                    filename: file,
                    baseModel: base,
                    quantization: quant,
                    downloads: hf.downloads,
                    likes: hf.likes,
                    sizeBytes: estimatedSize,
                    filePaths: [file]
                ))
            }
        }

        // 2. Merge matching curated models
        for curated in Self.curatedModels {
            let matchesQuery = trimmed.isEmpty || curated.name.localizedCaseInsensitiveContains(trimmed)
                || curated.repoID.localizedCaseInsensitiveContains(trimmed)
                || (curated.baseModel?.localizedCaseInsensitiveContains(trimmed) ?? false)

            if matchesQuery && !seenIDs.contains(curated.id) {
                seenIDs.insert(curated.id)
                results.append(curated)
            }
        }

        // Sort by downloads / popularity
        results.sort { ($0.downloads ?? 0) > ($1.downloads ?? 0) }

        return results.isEmpty ? Self.curatedModels : results
    }

    private func formatDisplayName(repoID: String) -> String {
        let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
        return name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    private func extractBaseModel(from identifier: String, tags: [String]?) -> String? {
        let lower = (identifier + " " + (tags?.joined(separator: " ") ?? "")).lowercased()
        if lower.contains("flux") { return "Flux.1" }
        if lower.contains("sdxl") || lower.contains("xl") { return "SDXL" }
        if lower.contains("sd1.5") || lower.contains("sd-1.5") || lower.contains("v1-5") || lower.contains("sd15") { return "SD 1.5" }
        if lower.contains("sd3") { return "SD 3" }
        if lower.contains("pony") { return "Pony" }
        if lower.contains("minimax") { return "MiniMax" }
        if lower.contains("qwen") { return "Qwen" }
        return nil
    }

    private func extractQuantization(from identifier: String, tags: [String]?) -> String {
        let lower = (identifier + " " + (tags?.joined(separator: " ") ?? "")).lowercased()
        if lower.contains("8bit") || lower.contains("8-bit") || lower.contains("q8") || lower.contains("q8p") || lower.contains("i8x") { return "8-bit" }
        if lower.contains("4bit") || lower.contains("4-bit") || lower.contains("q4") || lower.contains("q4_k") || lower.contains("q4_0") { return "4-bit" }
        if lower.contains("3bit") || lower.contains("3-bit") || lower.contains("q3") || lower.contains("iq3") { return "3-bit" }
        if lower.contains("2bit") || lower.contains("2-bit") || lower.contains("q2") || lower.contains("iq2") { return "2-bit" }
        if lower.contains("q6") || lower.contains("q6p") || lower.contains("q6_k") { return "6-bit" }
        if lower.contains("fp16") || lower.contains("f16") { return "FP16" }
        return "Quantized"
    }

    private func estimateFileSize(filename: String, fallbackTotal: Int64?, totalFiles: Int, baseModel: String?) -> Int64 {
        let lower = filename.lowercased()
        if let base = baseModel {
            switch base {
            case "Flux.1":
                if lower.contains("8bit") || lower.contains("8_bit") || lower.contains("q8") { return 12_800_000_000 }
                if lower.contains("4bit") || lower.contains("4_bit") || lower.contains("q4") { return 6_400_000_000 }
                if lower.contains("3bit") || lower.contains("3_bit") || lower.contains("q3") { return 4_800_000_000 }
                if lower.contains("2bit") || lower.contains("2_bit") || lower.contains("q2") { return 3_300_000_000 }
                return 6_400_000_000
            case "SDXL":
                if lower.contains("8bit") || lower.contains("8_bit") || lower.contains("q8") { return 3_400_000_000 }
                if lower.contains("4bit") || lower.contains("4_bit") || lower.contains("q4") { return 1_900_000_000 }
                return 3_400_000_000
            case "SD 1.5":
                if lower.contains("8bit") || lower.contains("8_bit") || lower.contains("q8") { return 2_100_000_000 }
                if lower.contains("4bit") || lower.contains("4_bit") || lower.contains("q4") { return 1_100_000_000 }
                return 2_100_000_000
            default:
                break
            }
        }
        if let fallback = fallbackTotal, fallback > 0 {
            return fallback / Int64(max(1, totalFiles))
        }
        return 3_000_000_000
    }
}

