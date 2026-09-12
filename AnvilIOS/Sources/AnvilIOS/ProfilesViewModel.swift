import Foundation
import AnvilCore
import Observation

/// Reusable system prompts ("personas"), optionally bound as the
/// default for one registered text model — always backed by this
/// phone's own local `ChatProfileStore`. When Chat's source picker has
/// an active Mac, `ChatThreadsViewModel` calls `mergeSync(host:)`
/// periodically: any profile that exists on only one side gets pushed
/// to the other, so a profile made on the Mac and a different one made
/// on the phone both end up on both devices — no manual exporting or
/// picking "whose version wins" needed for the common case of two
/// different profiles.
@Observable
@MainActor
final class ProfilesViewModel {
    var profiles: [ChatProfile] = []
    var errorMessage: String?

    private let store = ChatProfileStore()
    private let syncClient = AnvilSyncClient()

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

    /// A profile with the same `id` on both sides is treated as
    /// identical (profiles don't carry an `updatedAt` to arbitrate a
    /// same-ID edit conflict — a genuinely rare case for something
    /// that's usually created once, not repeatedly edited from two
    /// devices at once); everything else is a plain union: whichever
    /// side is missing a profile gets it pushed to it.
    func mergeSync(host: String) async {
        guard let remoteProfiles = try? await syncClient.profiles(host: host) else { return }
        let localAll = await store.all()
        let localIDs = Set(localAll.map(\.id))
        let remoteIDs = Set(remoteProfiles.map(\.id))

        for profile in remoteProfiles where !localIDs.contains(profile.id) {
            _ = try? await store.upsert(profile)
        }
        for profile in localAll where !remoteIDs.contains(profile.id) {
            _ = try? await syncClient.upsertProfile(profile, host: host)
        }
        await load()
    }
}
