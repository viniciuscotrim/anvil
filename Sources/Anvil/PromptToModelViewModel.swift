import Foundation
import AnvilCore
import Observation

/// One registered image model's row: the tailored prompt an
/// interpreting text model wrote for it (editable), and that row's own
/// independent generate/load state.
struct PromptToModelRow: Identifiable {
    let model: ModelEntry
    var prompt: String
    var isGenerating = false
    var generationProgress: Double?
    var errorMessage: String?
    var lastGeneratedImage: GeneratedImage?
    var id: String { model.id }
}

/// "Prompt to Model": type a plain-language image idea, pick a loaded
/// text model to interpret it, and get one tailored, editable prompt
/// per registered image model — each with its own Generate button that
/// loads that model on demand if needed and saves the result into the
/// Images tab's history like any other generation.
///
@MainActor
@Observable
final class PromptToModelViewModel {
    var intention: String = ""
    var selectedTextModelID: String?
    private(set) var rows: [PromptToModelRow] = []
    private(set) var isInterpreting = false
    var errorMessage: String?

    @ObservationIgnored
    private let sessions: ModelSessionManager
    @ObservationIgnored
    private let imageSessions: ImageSessionManager
    @ObservationIgnored
    private let modelRegistry: ModelRegistry
    @ObservationIgnored
    private let requirements: RequirementsManager
    @ObservationIgnored
    private let generatedImageStore: GeneratedImageStore
    @ObservationIgnored
    private let chatClient = ChatClient()
    @ObservationIgnored
    private let imageClient = ImageClient()

    init(
        sessions: ModelSessionManager,
        imageSessions: ImageSessionManager,
        modelRegistry: ModelRegistry,
        requirements: RequirementsManager,
        generatedImageStore: GeneratedImageStore
    ) {
        self.sessions = sessions
        self.imageSessions = imageSessions
        self.modelRegistry = modelRegistry
        self.requirements = requirements
        self.generatedImageStore = generatedImageStore
    }

    func syncSelectedTextModel() {
        if let id = selectedTextModelID, sessions.isLoaded(modelID: id) { return }
        selectedTextModelID = sessions.readySessions.first?.id
    }

    /// Asks the selected text model to write one tailored prompt per
    /// registered image model, from `intention`. Every registered image
    /// model always ends up with a row and a usable prompt — a model
    /// whose output doesn't name a given image model by its exact
    /// display name (a real risk with smaller local models) just falls
    /// back to `intention` verbatim for that one row, rather than
    /// leaving it blank or dropping it.
    func interpret() async {
        let trimmedIntention = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIntention.isEmpty else {
            errorMessage = "Describe the image you want first."
            return
        }
        guard let textModelID = selectedTextModelID, let endpoint = sessions.chatEndpoint(for: textModelID) else {
            errorMessage = "Load a text model to interpret your idea first."
            return
        }
        let imageModels = await modelRegistry.all().filter { $0.kind == .image }
        guard !imageModels.isEmpty else {
            errorMessage = "No image models are registered yet — add one in the Models tab first."
            return
        }

        errorMessage = nil
        isInterpreting = true
        defer { isInterpreting = false }

        let modelNames = imageModels.map(\.displayName)
        let instruction = """
        You turn a user's plain-language image idea into a detailed, effective image-generation prompt, \
        tailored separately for each of these image models: \(modelNames.map { "\"\($0)\"" }.joined(separator: ", ")).

        User's idea: "\(trimmedIntention)"

        Write image-generation prompts in English regardless of what language the idea was written in — \
        richly descriptive, the way a skilled prompt engineer would for that specific kind of model. \
        Respond with ONLY a JSON object — no markdown, no explanation before or after — whose keys are \
        exactly these model names and whose values are that model's prompt text:
        {"\(modelNames.first ?? "model name")": "prompt text", ...}
        """

        do {
            let reply = try await chatClient.send(
                messages: [ChatMessage(role: .user, content: instruction)],
                baseURL: endpoint
            )
            let parsed = Self.parsePrompts(from: reply.content)
            rows = imageModels.map { model in
                let prompt = Self.matchedPrompt(for: model.displayName, in: parsed) ?? trimmedIntention
                return PromptToModelRow(model: model, prompt: prompt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Generates this row's (possibly hand-edited) prompt through its
    /// own model — loading it on demand if it isn't already resident —
    /// and saves the result into the shared `GeneratedImageStore`, the
    /// same one the Images tab's gallery/version-history reads from.
    func generateRow(_ rowID: String) async {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let prompt = rows[index].prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !rows[index].isGenerating else { return }
        let model = rows[index].model

        rows[index].errorMessage = nil
        rows[index].isGenerating = true
        rows[index].generationProgress = nil
        defer {
            if let currentIndex = rows.firstIndex(where: { $0.id == rowID }) {
                rows[currentIndex].isGenerating = false
                rows[currentIndex].generationProgress = nil
            }
        }

        if !imageSessions.isLoaded(modelID: model.id) {
            let loaded = await imageSessions.load(model, requirements: requirements)
            guard loaded else {
                let reason = imageSessions.session(for: model.id)?.status
                let detail: String
                if case .failed(let message) = reason { detail = message } else { detail = "could not load the model" }
                setRowError(rowID, detail)
                return
            }
        }
        guard let endpoint = imageSessions.imageEndpoint(for: model.id) else {
            setRowError(rowID, "the image model isn't ready")
            return
        }

        let imageSettings = ImageGenerationSettings(
            width: model.defaultImageWidth ?? ImageGenerationSettings.default.width,
            height: model.defaultImageHeight ?? ImageGenerationSettings.default.height
        )

        do {
            let result = try await imageClient.generate(
                prompt: prompt,
                baseURL: endpoint,
                settings: imageSettings
            ) { [weak self] progress in
                Task { @MainActor in self?.setRowProgress(rowID, progress.fraction) }
            }
            let saved = try await generatedImageStore.add(GeneratedImage(
                prompt: prompt,
                modelDisplayName: model.displayName,
                localPath: result.localPath,
                width: result.width,
                height: result.height,
                seed: result.seed
            ))
            if let currentIndex = rows.firstIndex(where: { $0.id == rowID }) {
                rows[currentIndex].lastGeneratedImage = saved
            }
            if model.keepImageModelLoadedInChat == false {
                await imageSessions.unload(modelID: model.id)
            }
        } catch {
            setRowError(rowID, error.localizedDescription)
        }
    }

    func updatePrompt(_ rowID: String, to text: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].prompt = text
    }

    private func setRowError(_ rowID: String, _ message: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].errorMessage = message
    }

    private func setRowProgress(_ rowID: String, _ fraction: Double?) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].generationProgress = fraction
    }

    /// Extracts the first `{...}` JSON object in `text` — local models
    /// sometimes wrap JSON in a sentence or a markdown code fence
    /// despite being asked not to, so this looks for the outermost
    /// braces rather than requiring the whole reply to parse as-is.
    static func parsePrompts(from text: String) -> [String: String] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return [:]
        }
        let jsonSubstring = text[start...end]
        guard let data = jsonSubstring.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    /// Exact match first, then case/whitespace-insensitive — a local
    /// model asked to use an exact key sometimes still normalizes case
    /// or trims it slightly.
    static func matchedPrompt(for modelName: String, in parsed: [String: String]) -> String? {
        if let exact = parsed[modelName] { return exact }
        let normalized = modelName.trimmingCharacters(in: .whitespaces).lowercased()
        for (key, value) in parsed where key.trimmingCharacters(in: .whitespaces).lowercased() == normalized {
            return value
        }
        return nil
    }
}
