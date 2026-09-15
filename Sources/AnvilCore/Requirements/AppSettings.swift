import Foundation

/// A tiny persisted key-value store for app-level preferences that
/// don't belong on any one model/thread/profile — today just the
/// optional custom folder for downloaded/imported models, plus the Code
/// agent's own settings. One JSON file, same pattern as the other
/// stores, but a plain struct (not an actor): callers just re-`load()`/
/// `save()` around each change instead of holding a long-lived
/// instance.
///
/// Not actually main-actor-only in practice — `load()` runs from
/// background download-preparation code too (`ModelDownloader`'s own
/// `destinationDirectory`, for one), concurrently with a UI-driven
/// `save()`. That's an accepted, narrow trade-off rather than an
/// oversight: `save()` writes atomically, so a concurrent `load()`
/// always sees either the old or the new complete file, never a torn
/// one — the only real failure mode is a rare "lost update" (two
/// concurrent load-mutate-save cycles racing, the later one winning
/// outright) for a value that's just a user preference, cheaply
/// corrected by setting it again. Serializing every read/write behind
/// an actor (like `ModelRegistry` does) would close that gap, but at
/// the cost of making all ~40 call sites across both apps `async` for
/// a race this unlikely and this recoverable — not a trade worth
/// making today.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Where new downloads land and where "scan for existing models"
    /// looks — nil means the default, `RuntimePaths.modelsDirectory`.
    public var modelsRootPath: String?
    /// Which registered image model (`ModelEntry.id`) `generate_image`
    /// tool calls in chat should prefer when more than one is loaded or
    /// registered — nil means "no explicit preference", the old
    /// behavior (whichever's already loaded, or the first registered
    /// one found). Set from a toggle on the model's own gear settings
    /// in the Models tab; picking one there clears it from any other
    /// model, so at most one is ever the default.
    public var defaultChatImageModelID: String?
    /// Which registered text model (`ModelEntry.id`) "Suggest from
    /// Thread" should use — nil means "whichever model Chat currently
    /// has selected". Unlike `defaultChatImageModelID`, this can name a
    /// model that isn't loaded (or isn't even registered as text) at
    /// all right now; picking one here doesn't load it — that only
    /// happens on demand when Suggest is actually pressed. See
    /// `ChatViewModel.suggestMemoriesFromCurrentThread`'s doc comment.
    public var memorySuggestionModelID: String?
    /// Chat composer quiet period. Zero sends on submit immediately; a
    /// positive value batches blocks until the user stops typing.
    public var chatMessageWaitSeconds: Double
    public var chatMaxEstimatedContextTokens: Int
    public var chatRecentMessageCount: Int

    /// The Code tab's own working folder — nil until the user picks
    /// one. `read_file`/`list_directory`/`write_file`/
    /// `run_terminal_command` all confine themselves to this folder
    /// unless `codeAgentAllowFullDiskAccess` is on.
    public var codeAgentWorkingDirectoryPath: String?
    /// Off by default — an explicit opt-in the user has to reach into
    /// Settings for, not something a working-folder pick alone implies.
    public var codeAgentAllowFullDiskAccess: Bool
    public var codeAgentPermissionLevel: CodeAgentPermissionLevel
    /// Off (empty) by default — the whole point of "a menu of features
    /// you can turn on and off" is that nothing is granted until the
    /// user opts in.
    public var codeAgentEnabledFeatures: Set<CodeAgentFeature>

    /// Whether `AnvilSyncServer` (a separate, additive server exposing
    /// this Mac's own threads/profiles/memories to a phone on the same
    /// network) runs at all — off by default, same "nothing is exposed
    /// until the user opts in" rule every other network-facing feature
    /// here already follows.
    public var isMacSyncEnabled: Bool
    /// Reuses the same Local-only/Network semantic every per-model
    /// server already exposes via its own gear icon.
    public var macSyncAccess: ServerAccess
    /// Off by default — `CloudSyncEngine` (threads/profiles/memories
    /// through the user's own private iCloud database) never runs
    /// until this is explicitly turned on, the same "opt-in, works
    /// fully without it" rule `isMacSyncEnabled` already follows.
    public var isCloudSyncEnabled: Bool

    public init(
        modelsRootPath: String? = nil,
        defaultChatImageModelID: String? = nil,
        memorySuggestionModelID: String? = nil,
        chatMessageWaitSeconds: Double = 10,
        chatMaxEstimatedContextTokens: Int = 24_000,
        chatRecentMessageCount: Int = 12,
        codeAgentWorkingDirectoryPath: String? = nil,
        codeAgentAllowFullDiskAccess: Bool = false,
        codeAgentPermissionLevel: CodeAgentPermissionLevel = .manual,
        codeAgentEnabledFeatures: Set<CodeAgentFeature> = [],
        isMacSyncEnabled: Bool = false,
        macSyncAccess: ServerAccess = .localOnly,
        isCloudSyncEnabled: Bool = false
    ) {
        self.modelsRootPath = modelsRootPath
        self.defaultChatImageModelID = defaultChatImageModelID
        self.memorySuggestionModelID = memorySuggestionModelID
        self.chatMessageWaitSeconds = chatMessageWaitSeconds
        self.chatMaxEstimatedContextTokens = chatMaxEstimatedContextTokens
        self.chatRecentMessageCount = chatRecentMessageCount
        self.codeAgentWorkingDirectoryPath = codeAgentWorkingDirectoryPath
        self.codeAgentAllowFullDiskAccess = codeAgentAllowFullDiskAccess
        self.codeAgentPermissionLevel = codeAgentPermissionLevel
        self.codeAgentEnabledFeatures = codeAgentEnabledFeatures
        self.isMacSyncEnabled = isMacSyncEnabled
        self.macSyncAccess = macSyncAccess
        self.isCloudSyncEnabled = isCloudSyncEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case modelsRootPath, defaultChatImageModelID, memorySuggestionModelID, chatMessageWaitSeconds
        case chatMaxEstimatedContextTokens, chatRecentMessageCount
        case codeAgentWorkingDirectoryPath, codeAgentAllowFullDiskAccess
        case codeAgentPermissionLevel, codeAgentEnabledFeatures
        case isMacSyncEnabled, macSyncAccess, isCloudSyncEnabled
    }

    // A settings file saved before a field existed just defaults it on
    // next load — plain `Codable` synthesis would instead fail to
    // decode the whole file the moment a *non-Optional* field like
    // `codeAgentAllowFullDiskAccess` was added, and `load()`'s `try?`
    // would silently fall back to a brand-new `AppSettings()`, wiping
    // every setting that already existed (including `modelsRootPath`).
    // Real risk the moment this type grows past its original two
    // Optional-only fields, so it gets the same tolerant decoder every
    // other persisted type here already has.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelsRootPath = try container.decodeIfPresent(String.self, forKey: .modelsRootPath)
        defaultChatImageModelID = try container.decodeIfPresent(String.self, forKey: .defaultChatImageModelID)
        memorySuggestionModelID = try container.decodeIfPresent(String.self, forKey: .memorySuggestionModelID)
        chatMessageWaitSeconds = try container.decodeIfPresent(Double.self, forKey: .chatMessageWaitSeconds) ?? 10
        chatMaxEstimatedContextTokens = try container.decodeIfPresent(Int.self, forKey: .chatMaxEstimatedContextTokens) ?? 24_000
        chatRecentMessageCount = try container.decodeIfPresent(Int.self, forKey: .chatRecentMessageCount) ?? 12
        codeAgentWorkingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .codeAgentWorkingDirectoryPath)
        codeAgentAllowFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .codeAgentAllowFullDiskAccess) ?? false
        codeAgentPermissionLevel = try container.decodeIfPresent(CodeAgentPermissionLevel.self, forKey: .codeAgentPermissionLevel) ?? .manual
        codeAgentEnabledFeatures = try container.decodeIfPresent(Set<CodeAgentFeature>.self, forKey: .codeAgentEnabledFeatures) ?? []
        isMacSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMacSyncEnabled) ?? false
        macSyncAccess = try container.decodeIfPresent(ServerAccess.self, forKey: .macSyncAccess) ?? .localOnly
        isCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCloudSyncEnabled) ?? false
    }

    private static var fileURL: URL {
        RuntimePaths.applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder.anvil.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save() throws {
        let directory = Self.fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(self)
        try data.write(to: Self.fileURL, options: .atomic)
    }

    /// The folder new downloads land in and "scan for existing models"
    /// looks in — the custom root if set (and it still exists on disk),
    /// else Anvil's own default under Application Support. `registry.json`
    /// itself never moves — only where the actual model *files* live.
    public var effectiveModelsRoot: URL {
        if let modelsRootPath, FileManager.default.fileExists(atPath: modelsRootPath) {
            return URL(fileURLWithPath: modelsRootPath, isDirectory: true)
        }
        return RuntimePaths.modelsDirectory
    }

    /// The Code agent's working folder, resolved — nil if none is set or
    /// it no longer exists on disk (e.g. moved/deleted outside the app).
    public var codeAgentWorkingDirectory: URL? {
        guard let codeAgentWorkingDirectoryPath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codeAgentWorkingDirectoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: codeAgentWorkingDirectoryPath, isDirectory: true)
    }
}
