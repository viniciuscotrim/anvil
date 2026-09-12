import Foundation
import AnvilCore
import Observation

/// Reusable system prompts ("personas"), optionally bound as the
/// default for one registered text model — the same `ChatProfileStore`
/// the Mac app's Profiles tab uses, no changes needed for iOS.
@Observable
@MainActor
final class ProfilesViewModel {
    var profiles: [ChatProfile] = []
    var errorMessage: String?

    private let store = ChatProfileStore()

    func load() async {
        profiles = await store.all()
    }

    @discardableResult
    func save(_ profile: ChatProfile) async -> ChatProfile? {
        do {
            let saved = try await store.upsert(profile)
            await load()
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ profile: ChatProfile) async {
        try? await store.delete(id: profile.id)
        await load()
    }

    func defaultProfile(forModelID modelID: String) async -> ChatProfile? {
        await store.defaultProfile(forModelID: modelID)
    }
}
