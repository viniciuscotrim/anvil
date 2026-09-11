import Foundation

/// Talks to Anvil's own `/v1/images/generations` endpoint
/// (`ImageServerScript`). The server already saves the PNG to disk and
/// returns its path — since Anvil and the server run on the same Mac,
/// the client reads that file directly rather than round-tripping the
/// (also-returned, for OpenAI-shape compatibility) base64 payload.
public struct ImageClient: Sendable {
    public struct Result: Sendable {
        public let localPath: String
        public let seed: Int
        public let width: Int
        public let height: Int
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func generate(
        prompt: String,
        baseURL: URL,
        settings: ImageGenerationSettings = .default,
        seed: Int? = nil
    ) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/images/generations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generation can genuinely take minutes for a large model/step count.
        request.timeoutInterval = 300

        struct RequestBody: Encodable {
            let prompt: String
            let size: String
            let steps: Int
            let guidance: Double
            let seed: Int?
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                prompt: prompt,
                size: "\(settings.width)x\(settings.height)",
                steps: settings.steps,
                guidance: settings.guidance,
                seed: seed
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServingError.requestFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ServingError.requestFailed("HTTP \(statusCode): \(body)")
        }

        let decoded: ImageGenerationResponse
        do {
            decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
        } catch {
            throw ServingError.requestFailed("Could not parse response: \(error.localizedDescription)")
        }

        guard let item = decoded.data.first else {
            throw ServingError.requestFailed("Response had no image")
        }
        return Result(localPath: item.path, seed: item.seed, width: item.width, height: item.height)
    }
}

private struct ImageGenerationResponse: Decodable {
    struct Item: Decodable {
        let path: String
        let seed: Int
        let width: Int
        let height: Int
    }
    let data: [Item]
}
