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

    public struct Progress: Sendable, Equatable {
        public let step: Int
        public let total: Int
        public let active: Bool

        public var fraction: Double? {
            guard total > 0 else { return nil }
            return Double(step) / Double(total)
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// While the POST below is in flight, polls `GET
    /// /v1/images/progress` on the side (a separate connection — the
    /// server runs generation on one dedicated thread and answers this
    /// on others, so it's never blocked behind the request it's
    /// reporting on) and reports each reading through `onProgress`.
    public func generate(
        prompt: String,
        baseURL: URL,
        settings: ImageGenerationSettings = .default,
        seed: Int? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/images/generations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Anvil-Local")
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

        let progressTask: Task<Void, Never>? = onProgress.map { callback in
            Task {
                while !Task.isCancelled {
                    if let progress = try? await pollProgress(baseURL: baseURL) {
                        callback(progress)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        defer { progressTask?.cancel() }

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

    public func pollProgress(baseURL: URL) async throws -> Progress {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("v1/images/progress"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServingError.requestFailed("Could not read generation progress")
        }
        let decoded = try JSONDecoder().decode(ProgressResponse.self, from: data)
        return Progress(step: decoded.step, total: decoded.total, active: decoded.active)
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

private struct ProgressResponse: Decodable {
    let step: Int
    let total: Int
    let active: Bool
}
