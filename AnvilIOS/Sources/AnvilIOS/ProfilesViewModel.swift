import Foundation
import AnvilCore
import Observation

/// Reusable system prompts ("personas"), optionally bound as the
/// default for one registered text model — the same `ChatProfileStore`
/// the Mac app's Profiles tab uses when the source is "This iPhone".
/// When Chat's source menu picks a Mac with sync enabled instead,
/// `setActiveHost(_:)` (called by `ChatThreadsViewModel.selectSource`)
/// switches this to read/write that Mac's own profiles via
/// `AnvilSyncClient` — same profiles the Mac app's own Profiles tab
/// shows, updated there even when the edit came from the phone.
@Observable
@MainActor
final class ProfilesViewModel {
    var profiles: [ChatProfile] = []
    var errorMessage: String?

    private let store = ChatProfileStore()
    private let syncClient = AnvilSyncClient()
    private var activeHost: String?

    func setActiveHost(_ host: String?) async {
        activeHost = host
        await load()
    }

    func load() async {
        if let activeHost {
            do {
                profiles = try await syncClient.profiles(host: activeHost)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            profiles = await store.all()
        }
    }

    @discardableResult
    func save(_ profile: ChatProfile) async -> ChatProfile? {
        do {
            let saved: ChatProfile
            if let activeHost {
                saved = try await syncClient.upsertProfile(profile, host: activeHost)
            } else {
                saved = try await store.upsert(profile)
            }
            await load()
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ profile: ChatProfile) async {
        do {
            if let activeHost {
                try await syncClient.deleteProfile(id: profile.id, host: activeHost)
            } else {
                try await store.delete(id: profile.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await load()
    }

    /// Only meaningful for the local store — a remote Mac's own default-
    /// per-model binding isn't something the phone's local model IDs
    /// have any relationship to.
    func defaultProfile(forModelID modelID: String) async -> ChatProfile? {
        guard activeHost == nil else { return nil }
        return await store.defaultProfile(forModelID: modelID)
    }
}
