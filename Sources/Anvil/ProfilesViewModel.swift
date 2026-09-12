import Foundation
import AnvilCore

/// Plain `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the `@State` toolchain note in README.
@MainActor
final class ProfilesViewModel: ObservableObject {
    @Published private(set) var profiles: [ChatProfile] = []
    @Published private(set) var registeredModels: [ModelEntry] = []
    @Published var errorMessage: String?

    /// Draft state for the create/edit sheet — nil when it's closed.
    @Published var editingDraft: Draft?

    struct Draft: Identifiable {
        var id: UUID?
        var name: String
        var prompt: String
        var defaultForModelID: String?

        static func new() -> Draft {
            Draft(id: nil, name: "", prompt: "", defaultForModelID: nil)
        }
    }

    private let store: ChatProfileStore
    private let registry: ModelRegistry

    init(store: ChatProfileStore, registry: ModelRegistry) {
        self.store = store
        self.registry = registry
    }

    func load() async {
        profiles = await store.all()
        registeredModels = await registry.all()
    }

    func startCreating() {
        editingDraft = .new()
    }

    func startEditing(_ profile: ChatProfile) {
        editingDraft = Draft(id: profile.id, name: profile.name, prompt: profile.prompt, defaultForModelID: profile.defaultForModelID)
    }

    /// The model bound to this draft's default, elsewhere: another
    /// profile already claims it, if any — shown so the user
    /// understands why picking a model here will move it.
    func currentDefaultHolder(for modelID: String, excluding draftID: UUID?) -> ChatProfile? {
        profiles.first { $0.defaultForModelID == modelID && $0.id != draftID }
    }

    func saveDraft() async {
        guard var draft = editingDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Give the profile a name."
            return
        }
        draft.name = name
        // Preserve an existing profile's origin on edit — only a
        // brand-new one gets tagged with this device.
        let existingOrigin = draft.id.flatMap { id in profiles.first { $0.id == id }?.originDeviceName }
        let profile = ChatProfile(
            id: draft.id ?? UUID(),
            name: name,
            prompt: draft.prompt,
            defaultForModelID: draft.defaultForModelID,
            originDeviceName: existingOrigin ?? DeviceIdentity.currentName
        )
        do {
            _ = try await store.upsert(profile)
            editingDraft = nil
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ profile: ChatProfile) async {
        try? await store.delete(id: profile.id)
        await load()
    }

    func modelDisplayName(for modelID: String?) -> String? {
        guard let modelID else { return nil }
        return registeredModels.first { $0.id == modelID }?.displayName
    }
}
