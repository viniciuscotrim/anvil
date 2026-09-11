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

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case downloads
        case likes
        case tags
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
            URLQueryItem(name: "direction", value: "-1")
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
