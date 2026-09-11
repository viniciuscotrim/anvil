import Foundation
import AnvilCore

/// Owns every app-level object as a single unit so they can reference
/// each other at construction time (a plain class init, not tangled
/// property-wrapper defaults). Holding every tab's view model here keeps
/// each one alive across tab switches — root cause of two real reported
/// bugs, fixed the same way both times: `ChatViewModel` was originally
/// a view-local `@StateObject`, torn down whenever `ChatView` left the
/// view tree, losing the conversation; `ModelManagerViewModel` had the
/// same bug later — switching away from Models and back tore it down
/// mid-download, so an in-flight download kept running in the
/// background (its `Task` held a strong `self` once started) but
/// disappeared from the UI, with no way to see or control it again.
@MainActor
final class AppState: ObservableObject {
    let requirements: RequirementsManager
    let sessions: ModelSessionManager
    let imageSessions: ImageSessionManager
    let threadStore: ChatThreadStore
    let generatedImageStore: GeneratedImageStore
    let profileStore: ChatProfileStore
    let modelRegistry: ModelRegistry
    let chat: ChatViewModel
    let imageGeneration: ImageGenerationViewModel
    let profiles: ProfilesViewModel
    let promptToModel: PromptToModelViewModel
    let modelManager: ModelManagerViewModel

    init() {
        let requirements = RequirementsManager()
        let sessions = ModelSessionManager()
        let imageSessions = ImageSessionManager()
        let threadStore = ChatThreadStore()
        let generatedImageStore = GeneratedImageStore()
        let profileStore = ChatProfileStore()
        let modelRegistry = ModelRegistry()
        self.requirements = requirements
        self.sessions = sessions
        self.imageSessions = imageSessions
        self.threadStore = threadStore
        self.generatedImageStore = generatedImageStore
        self.profileStore = profileStore
        self.modelRegistry = modelRegistry
        self.imageGeneration = ImageGenerationViewModel(imageSessions: imageSessions, store: generatedImageStore)
        self.chat = ChatViewModel(
            sessions: sessions,
            threadStore: threadStore,
            imageSessions: imageSessions,
            generatedImageStore: generatedImageStore,
            profileStore: profileStore,
            modelRegistry: modelRegistry,
            requirements: requirements
        )
        self.profiles = ProfilesViewModel(store: profileStore, registry: modelRegistry)
        self.promptToModel = PromptToModelViewModel(
            sessions: sessions,
            imageSessions: imageSessions,
            modelRegistry: modelRegistry,
            requirements: requirements,
            generatedImageStore: generatedImageStore
        )
        self.modelManager = ModelManagerViewModel(requirements: requirements)
    }
}
