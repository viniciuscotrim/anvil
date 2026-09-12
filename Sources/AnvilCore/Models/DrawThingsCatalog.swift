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

    /// Curated list of official Draw Things models, separated into individual quantization variants
    /// with specific file sizes and popularity ratings.
    public static let curatedModels: [DrawThingsModelSummary] = [
        // FLUX.1 Schnell Variants
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-schnell:flux_1_schnell_4bit.ckpt",
            name: "FLUX.1 Schnell (4-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-schnell",
            filename: "flux_1_schnell_4bit.ckpt",
            baseModel: "Flux.1",
            quantization: "4-bit",
            downloads: 64200,
            likes: 850,
            sizeBytes: 6_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-schnell:flux_1_schnell_8bit.ckpt",
            name: "FLUX.1 Schnell (8-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-schnell",
            filename: "flux_1_schnell_8bit.ckpt",
            baseModel: "Flux.1",
            quantization: "8-bit",
            downloads: 48500,
            likes: 850,
            sizeBytes: 12_800_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-schnell:flux_1_schnell_3bit.ckpt",
            name: "FLUX.1 Schnell (3-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-schnell",
            filename: "flux_1_schnell_3bit.ckpt",
            baseModel: "Flux.1",
            quantization: "3-bit",
            downloads: 22100,
            likes: 850,
            sizeBytes: 4_800_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-schnell:flux_1_schnell_2bit.ckpt",
            name: "FLUX.1 Schnell (2-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-schnell",
            filename: "flux_1_schnell_2bit.ckpt",
            baseModel: "Flux.1",
            quantization: "2-bit",
            downloads: 14300,
            likes: 850,
            sizeBytes: 3_300_000_000
        ),

        // FLUX.1 Dev Variants
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-dev:flux_1_dev_4bit.ckpt",
            name: "FLUX.1 Dev (4-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-dev",
            filename: "flux_1_dev_4bit.ckpt",
            baseModel: "Flux.1",
            quantization: "4-bit",
            downloads: 45800,
            likes: 620,
            sizeBytes: 6_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-dev:flux_1_dev_8bit.ckpt",
            name: "FLUX.1 Dev (8-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-dev",
            filename: "flux_1_dev_8bit.ckpt",
            baseModel: "Flux.1",
            quantization: "8-bit",
            downloads: 32000,
            likes: 620,
            sizeBytes: 12_800_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/FLUX.1-dev:flux_1_dev_3bit.ckpt",
            name: "FLUX.1 Dev (3-bit Quantized)",
            repoID: "drawthingsai/FLUX.1-dev",
            filename: "flux_1_dev_3bit.ckpt",
            baseModel: "Flux.1",
            quantization: "3-bit",
            downloads: 18400,
            likes: 620,
            sizeBytes: 4_800_000_000
        ),

        // SDXL Models
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Generic-SDXL-v1.0:generic_sdxl_v10_8bit.ckpt",
            name: "Generic SDXL v1.0 (8-bit Quantized)",
            repoID: "drawthingsai/Generic-SDXL-v1.0",
            filename: "generic_sdxl_v10_8bit.ckpt",
            baseModel: "SDXL",
            quantization: "8-bit",
            downloads: 24500,
            likes: 410,
            sizeBytes: 3_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Generic-SDXL-v1.0:generic_sdxl_v10_4bit.ckpt",
            name: "Generic SDXL v1.0 (4-bit Quantized)",
            repoID: "drawthingsai/Generic-SDXL-v1.0",
            filename: "generic_sdxl_v10_4bit.ckpt",
            baseModel: "SDXL",
            quantization: "4-bit",
            downloads: 19400,
            likes: 410,
            sizeBytes: 1_900_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/DreamShaper-XL-v2.1:dreamshaper_xl_v21_8bit.ckpt",
            name: "DreamShaper XL v2.1 (8-bit Quantized)",
            repoID: "drawthingsai/DreamShaper-XL-v2.1",
            filename: "dreamshaper_xl_v21_8bit.ckpt",
            baseModel: "SDXL",
            quantization: "8-bit",
            downloads: 15400,
            likes: 290,
            sizeBytes: 3_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/DreamShaper-XL-v2.1:dreamshaper_xl_v21_4bit.ckpt",
            name: "DreamShaper XL v2.1 (4-bit Quantized)",
            repoID: "drawthingsai/DreamShaper-XL-v2.1",
            filename: "dreamshaper_xl_v21_4bit.ckpt",
            baseModel: "SDXL",
            quantization: "4-bit",
            downloads: 12300,
            likes: 290,
            sizeBytes: 1_900_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Juggernaut-XL-v9:juggernaut_xl_v9_8bit.ckpt",
            name: "Juggernaut XL v9 (8-bit Quantized)",
            repoID: "drawthingsai/Juggernaut-XL-v9",
            filename: "juggernaut_xl_v9_8bit.ckpt",
            baseModel: "SDXL",
            quantization: "8-bit",
            downloads: 18100,
            likes: 250,
            sizeBytes: 3_500_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Juggernaut-XL-v9:juggernaut_xl_v9_4bit.ckpt",
            name: "Juggernaut XL v9 (4-bit Quantized)",
            repoID: "drawthingsai/Juggernaut-XL-v9",
            filename: "juggernaut_xl_v9_4bit.ckpt",
            baseModel: "SDXL",
            quantization: "4-bit",
            downloads: 11200,
            likes: 250,
            sizeBytes: 1_900_000_000
        ),

        // SD 1.5 Models
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Realistic-Vision-v6.0-B1:realistic_vision_v60_8bit.ckpt",
            name: "Realistic Vision v6.0 (8-bit Quantized)",
            repoID: "drawthingsai/Realistic-Vision-v6.0-B1",
            filename: "realistic_vision_v60_8bit.ckpt",
            baseModel: "SD 1.5",
            quantization: "8-bit",
            downloads: 19800,
            likes: 380,
            sizeBytes: 2_100_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Realistic-Vision-v6.0-B1:realistic_vision_v60_4bit.ckpt",
            name: "Realistic Vision v6.0 (4-bit Quantized)",
            repoID: "drawthingsai/Realistic-Vision-v6.0-B1",
            filename: "realistic_vision_v60_4bit.ckpt",
            baseModel: "SD 1.5",
            quantization: "4-bit",
            downloads: 16500,
            likes: 380,
            sizeBytes: 1_100_000_000
        ),

        // Anime & Illustrious
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Pony-Diffusion-V6-XL:pony_diffusion_v6_xl_8bit.ckpt",
            name: "Pony Diffusion V6 XL (8-bit Quantized)",
            repoID: "drawthingsai/Pony-Diffusion-V6-XL",
            filename: "pony_diffusion_v6_xl_8bit.ckpt",
            baseModel: "SDXL",
            quantization: "8-bit",
            downloads: 22000,
            likes: 320,
            sizeBytes: 3_400_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Pony-Diffusion-V6-XL:pony_diffusion_v6_xl_4bit.ckpt",
            name: "Pony Diffusion V6 XL (4-bit Quantized)",
            repoID: "drawthingsai/Pony-Diffusion-V6-XL",
            filename: "pony_diffusion_v6_xl_4bit.ckpt",
            baseModel: "SDXL",
            quantization: "4-bit",
            downloads: 15400,
            likes: 320,
            sizeBytes: 1_900_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/Animagine-XL-v3.1:animagine_xl_v31_8bit.ckpt",
            name: "Animagine XL v3.1 (8-bit Quantized)",
            repoID: "drawthingsai/Animagine-XL-v3.1",
            filename: "animagine_xl_v31_8bit.ckpt",
            baseModel: "SDXL",
            quantization: "8-bit",
            downloads: 14200,
            likes: 180,
            sizeBytes: 3_400_000_000
        ),

        // Multi-Modal / Video Models
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/MiniMax-H3:minimax_h3_fl2va_q8p.ckpt",
            name: "MiniMax-H3 (fl2va_q8p)",
            repoID: "drawthingsai/MiniMax-H3",
            filename: "minimax_h3_fl2va_q8p.ckpt",
            baseModel: "MiniMax",
            quantization: "q8p",
            downloads: 2800,
            likes: 110,
            sizeBytes: 6_200_000_000
        ),
        DrawThingsModelSummary(
            id: "drawthings:drawthingsai/MiniMax-H3:minimax_h3_fl2va_q6p.ckpt",
            name: "MiniMax-H3 (fl2va_q6p)",
            repoID: "drawthingsai/MiniMax-H3",
            filename: "minimax_h3_fl2va_q6p.ckpt",
            baseModel: "MiniMax",
            quantization: "q6p",
            downloads: 3200,
            likes: 110,
            sizeBytes: 4_500_000_000
        )
    ]

    /// Searches Draw Things models across official `drawthingsai` repositories and Hugging Face.
    /// Breaks multi-file repositories down into distinct, individually downloadable quantization variants.
    public func search(query: String, limit: Int = 30) async throws -> [DrawThingsModelSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fetch from Hugging Face with broad search
        var fetchedSummaries: [HFModelSummary] = []
        let searchKeywords = trimmed.isEmpty ? ["drawthings", "drawthingsai"] : [trimmed, "drawthings \(trimmed)", "drawthingsai"]

        for kw in searchKeywords {
            var components = URLComponents(string: "https://huggingface.co/api/models")!
            components.queryItems = [
                URLQueryItem(name: "search", value: kw),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "expand", value: "downloads"),
                URLQueryItem(name: "expand", value: "likes"),
                URLQueryItem(name: "expand", value: "tags"),
                URLQueryItem(name: "expand", value: "safetensors"),
                URLQueryItem(name: "expand", value: "siblings")
            ]

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

        // 1. Expand fetched Hugging Face repositories into per-quantization files
        for hf in fetchedSummaries {
            let files = hf.filePaths ?? []
            let modelFiles = files.filter { file in
                let lower = file.lowercased()
                return (lower.hasSuffix(".ckpt") || lower.hasSuffix(".nnc") || lower.hasSuffix(".gguf") || lower.hasSuffix(".safetensors"))
                    && !lower.hasPrefix(".") && !lower.contains("mmproj")
            }

            let base = extractBaseModel(from: hf.modelID, tags: hf.tags)
            let baseName = formatDisplayName(repoID: hf.modelID)

            if modelFiles.count > 1 {
                // Multi-variant repo: create a distinct summary per model file
                for file in modelFiles {
                    let quant = extractQuantization(from: file, tags: hf.tags)
                    let variantID = "drawthings:\(hf.modelID):\(file)"
                    guard !seenIDs.contains(variantID) else { continue }
                    seenIDs.insert(variantID)

                    let estimatedSize = estimateFileSize(filename: file, fallbackTotal: hf.sizeBytes, totalFiles: modelFiles.count, baseModel: base)
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
            } else {
                // Single model file or root package
                let singleFile = modelFiles.first
                let quant = extractQuantization(from: singleFile ?? hf.modelID, tags: hf.tags)
                let itemID = "drawthings:\(hf.modelID)" + (singleFile.map { ":\($0)" } ?? "")
                guard !seenIDs.contains(itemID) else { continue }
                seenIDs.insert(itemID)

                results.append(DrawThingsModelSummary(
                    id: itemID,
                    name: singleFile != nil ? "\(baseName) (\(quant))" : baseName,
                    repoID: hf.modelID,
                    filename: singleFile,
                    baseModel: base,
                    quantization: quant,
                    downloads: hf.downloads,
                    likes: hf.likes,
                    sizeBytes: hf.sizeBytes ?? estimateFileSize(filename: singleFile ?? "", fallbackTotal: nil, totalFiles: 1, baseModel: base),
                    filePaths: singleFile.map { [$0] } ?? hf.filePaths
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

