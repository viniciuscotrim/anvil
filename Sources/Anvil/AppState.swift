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
///
/// Deliberately not `@Observable`/`ObservableObject`: every property
/// here is a `let`, set once at init and never reassigned, so nothing
/// ever needs to react to *this* object changing — only to the
/// individually-`@Observable` view models it holds, each injected into
/// the environment on its own. Held by `AnvilApp` by a plain `@State`,
/// which for a reference type does exactly what's needed here (keeps
/// the same instance alive across view updates) without requiring any
/// observation machinery at all.
@MainActor
final class AppState {
    let requirements: RequirementsManager
    let residency: ResidencyPlanner
    let gateway: OpenAIGateway
    let sessions: ModelSessionManager
    let imageSessions: ImageSessionManager
    let threadStore: ChatThreadStore
    let generatedImageStore: GeneratedImageStore
    let profileStore: ChatProfileStore
    let memoryStore: ChatMemoryStore
    let suggestionStore: ChatMemorySuggestionStore
    let contextShift: ContextShiftCoordinator
    let modelRegistry: ModelRegistry
    let chat: ChatViewModel
    let imageGeneration: ImageGenerationViewModel
    let profiles: ProfilesViewModel
    let promptToModel: PromptToModelViewModel
    let modelManager: ModelManagerViewModel
    let codeAgent: CodeAgentViewModel

    init() {
        let requirements = RequirementsManager()
        let residency = ResidencyPlanner()
        let gateway = OpenAIGateway()
        let sessions = ModelSessionManager(residency: residency, gateway: gateway)
        let imageSessions = ImageSessionManager(residency: residency, gateway: gateway)
        let threadStore = ChatThreadStore()
        // Its own file, separate from Chat's threads.json — a Code
        // conversation (tool-call/result messages included) has no
        // business showing up in Chat's own history list or vice versa.
        let codeThreadStore = ChatThreadStore(
            fileURL: RuntimePaths.applicationSupportDirectory
                .appendingPathComponent("code", isDirectory: true)
                .appendingPathComponent("threads.json")
        )
        let generatedImageStore = GeneratedImageStore()
        let profileStore = ChatProfileStore()
        let memoryStore = ChatMemoryStore()
        let suggestionStore = ChatMemorySuggestionStore()
        let contextShift = ContextShiftCoordinator()
        let modelRegistry = ModelRegistry()
        self.requirements = requirements
        self.residency = residency
        self.gateway = gateway
        self.sessions = sessions
        self.imageSessions = imageSessions
        self.threadStore = threadStore
        self.generatedImageStore = generatedImageStore
        self.profileStore = profileStore
        self.memoryStore = memoryStore
        self.suggestionStore = suggestionStore
        self.contextShift = contextShift
        self.modelRegistry = modelRegistry
        self.imageGeneration = ImageGenerationViewModel(imageSessions: imageSessions, store: generatedImageStore)
        self.chat = ChatViewModel(
            sessions: sessions,
            threadStore: threadStore,
            imageSessions: imageSessions,
            generatedImageStore: generatedImageStore,
            profileStore: profileStore,
            memoryStore: memoryStore,
            suggestionStore: suggestionStore,
            contextShift: contextShift,
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
        self.codeAgent = CodeAgentViewModel(sessions: sessions, threadStore: codeThreadStore, requirements: requirements)
        Task { try? await gateway.start() }
    }
}
