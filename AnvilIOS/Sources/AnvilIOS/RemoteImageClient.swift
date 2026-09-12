import AnvilCore
import Foundation
import UIKit

/// Talks to the same `/v1/images/generations` endpoint AnvilCore's own
/// `ImageClient` does — but that type always sends `X-Anvil-Local: 1`
/// and only ever reads the response's local file `path` (correct for
/// the Mac app itself, since the server and the client share a disk;
/// meaningless from a phone, which has no access to the Mac's
/// filesystem). `ImageServerScript`'s own real behavior already covers
/// this: it only includes the image as base64 (`b64_json`) when that
/// header is *absent* — confirmed straight from its source, not
/// guessed — so this client just doesn't send it, and decodes the
/// image bytes directly instead of a path. No Mac-side change needed;
/// the endpoint already does the right thing for a non-local caller.
struct RemoteImageClient {
    struct Result {
        let image: UIImage
        let seed: Int
        let width: Int
        let height: Int
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        prompt: String,
        baseURL: URL,
        settings: ImageGenerationSettings,
        seed: Int? = nil
    ) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/images/generations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Deliberately no X-Anvil-Local header — see this type's own
        // doc comment for why that's what makes the server include the
        // actual image bytes instead of a Mac-only local path.
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteImageClientError.requestFailed("HTTP \(statusCode): \(body)")
        }

        let decoded: ImageGenerationResponse
        do {
            decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
        } catch {
            throw RemoteImageClientError.requestFailed("Could not parse response: \(error.localizedDescription)")
        }
        guard let item = decoded.data.first else {
            throw RemoteImageClientError.requestFailed("Response had no image")
        }
        guard let base64 = item.b64_json, let imageData = Data(base64Encoded: base64), let image = UIImage(data: imageData) else {
            throw RemoteImageClientError.requestFailed(
                "The Mac didn't send image data — this only works talking to Anvil's own image server.")
        }
        return Result(image: image, seed: item.seed, width: item.width, height: item.height)
    }
}

enum RemoteImageClientError: LocalizedError {
    case requestFailed(String)
    var errorDescription: String? {
        switch self {
        case .requestFailed(let reason): return reason
        }
    }
}

private struct ImageGenerationResponse: Decodable {
    struct Item: Decodable {
        let b64_json: String?
        let seed: Int
        let width: Int
        let height: Int
    }
    let data: [Item]
}
