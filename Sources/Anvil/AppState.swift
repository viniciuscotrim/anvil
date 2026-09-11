import Foundation
import AnvilCore

/// Owns every app-level object as a single unit so they can reference
/// each other at construction time (a plain class init, not tangled
/// property-wrapper defaults). Holding this one object at the App level
/// keeps `chat` alive across tab switches — root cause of an earlier
/// bug where navigating away from Chat and back lost the conversation:
/// `ChatViewModel` was a view-local `@StateObject`, torn down whenever
/// `ChatView` left the view tree.
@MainActor
final class AppState: ObservableObject {
    let requirements: RequirementsManager
    let sessions: ModelSessionManager
    let imageSessions: ImageSessionManager
    let threadStore: ChatThreadStore
    let generatedImageStore: GeneratedImageStore
    let chat: ChatViewModel
    let imageGeneration: ImageGenerationViewModel

    init() {
        let requirements = RequirementsManager()
        let sessions = ModelSessionManager()
        let imageSessions = ImageSessionManager()
        let threadStore = ChatThreadStore()
        let generatedImageStore = GeneratedImageStore()
        self.requirements = requirements
        self.sessions = sessions
        self.imageSessions = imageSessions
        self.threadStore = threadStore
        self.generatedImageStore = generatedImageStore
        self.imageGeneration = ImageGenerationViewModel(imageSessions: imageSessions, store: generatedImageStore)
        self.chat = ChatViewModel(
            sessions: sessions,
            threadStore: threadStore,
            imageSessions: imageSessions,
            generatedImageStore: generatedImageStore
        )
    }
}
