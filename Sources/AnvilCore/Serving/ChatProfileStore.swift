import Foundation

/// Persists chat profiles to one JSON file — same pattern as
/// `ModelRegistry`. Always re-reads the file rather than caching in
/// memory: both `ChatViewModel` and the Profiles screen hold their own
/// instance, and a stale cache in one would mean it never sees a
/// profile created/edited through the other. The file is tiny and reads
/// are infrequent, so re-reading every time costs nothing that matters.
public actor ChatProfileStore {
    private let fileURL: URL
    private let tombstones: TombstoneLog

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory.appendingPathComponent("profiles.json")
    ) {
        self.fileURL = fileURL
        tombstones = TombstoneLog(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("profiles_deleted.json")
        )
    }

    /// Newest first.
    public func all() -> [ChatProfile] {
        load().sorted { $0.createdAt > $1.createdAt }
    }

    public func get(id: UUID) -> ChatProfile? {
        load().first { $0.id == id }
    }

    /// The profile (if any) marked default for this registered model.
    public func defaultProfile(forModelID modelID: String) -> ChatProfile? {
        load().first { $0.defaultForModelID == modelID }
    }

    @discardableResult
    public func upsert(_ profile: ChatProfile) throws -> ChatProfile {
        var profiles = load()
        let profile = profile
        // At most one profile can default to a given model — claiming
        // it here releases it from whichever profile held it before.
        if let modelID = profile.defaultForModelID {
            for index in profiles.indices
            where profiles[index].id != profile.id && profiles[index].defaultForModelID == modelID {
                profiles[index].defaultForModelID = nil
            }
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist(profiles)
        return profile
    }

    public func delete(id: UUID) async throws {
        var profiles = load()
        profiles.removeAll { $0.id == id }
        try persist(profiles)
        try await tombstones.record(id)
    }

    /// See `ChatThreadStore.deletionTimestamps` — same tombstone
    /// mechanism. This is what actually fixes "I delete a profile and
    /// it comes right back": `ProfilesViewModel.mergeSync` used to be a
    /// plain union (whichever side is missing a profile gets it pushed
    /// back to it), which cannot distinguish "never existed on the
    /// other side" from "existed, but was just deleted" — every ~3s
    /// merge tick after a delete would see the profile "missing" here
    /// and immediately restore it from whichever device still had it.
    public func deletionTimestamps() async -> [UUID: Date] {
        await tombstones.all()
    }

    private func load() -> [ChatProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ChatProfile].self, from: data)) ?? []
    }

    private func persist(_ profiles: [ChatProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
