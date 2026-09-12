import AnvilCore
import Foundation
import UIKit

/// Images generated through a model already loaded on a Mac on the same
/// network — see `RemoteImageClient`'s own header comment for why the
/// Mac side needs zero changes for this to work. Chat's own remote path
/// lives in `RemoteChatEngine`/`NativeChatView` now (a Mac connection is
/// picked from Chat's own source menu, not a second chat screen here) —
/// this view model is Images-only. Connection discovery/management is a
/// separate, sibling `RemoteConnectionsViewModel` (shared with Chat's
/// source menu) rather than owned here, so both stay independently
/// observable by the view instead of one silently going stale inside
/// the other.
@MainActor
final class RemoteMacViewModel: ObservableObject {
    @Published var selectedImageConnectionID: UUID?
    @Published var imagePrompt = "a photo of an astronaut riding a horse on the moon"
    @Published private(set) var isGenerating = false
    @Published private(set) var lastImage: UIImage?
    @Published var imageSettings = ImageGenerationSettings.default
    @Published var errorMessage: String?

    private let imageClient = RemoteImageClient()

    func generateImage(using connection: RemoteMacConnection?) async {
        guard let connection, let baseURL = connection.baseURL else {
            errorMessage = "Add and pick a Mac image connection first."
            return
        }
        let text = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        do {
            let result = try await imageClient.generate(prompt: text, baseURL: baseURL, settings: imageSettings)
            lastImage = result.image
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
