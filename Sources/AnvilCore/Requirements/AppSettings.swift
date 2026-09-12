import Foundation

/// A tiny persisted key-value store for app-level preferences that
/// don't belong on any one model/thread/profile — today just the
/// optional custom folder for downloaded/imported models, plus the Code
/// agent's own settings. One JSON file, same pattern as the other
/// stores, but a plain struct (not an actor) since it's only ever
/// touched from the main actor UI and writes are small and infrequent —
/// callers just re-`load()`/`save()` around each change instead of
/// holding a long-lived instance.
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
    /// Chat composer quiet period. Zero sends on submit immediately; a
    /// positive value batches blocks until the user stops typing.
    public var chatMessageWaitSeconds: Double

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

    public init(
        modelsRootPath: String? = nil,
        defaultChatImageModelID: String? = nil,
        chatMessageWaitSeconds: Double = 10,
        codeAgentWorkingDirectoryPath: String? = nil,
        codeAgentAllowFullDiskAccess: Bool = false,
        codeAgentPermissionLevel: CodeAgentPermissionLevel = .manual,
        codeAgentEnabledFeatures: Set<CodeAgentFeature> = []
    ) {
        self.modelsRootPath = modelsRootPath
        self.defaultChatImageModelID = defaultChatImageModelID
        self.chatMessageWaitSeconds = chatMessageWaitSeconds
        self.codeAgentWorkingDirectoryPath = codeAgentWorkingDirectoryPath
        self.codeAgentAllowFullDiskAccess = codeAgentAllowFullDiskAccess
        self.codeAgentPermissionLevel = codeAgentPermissionLevel
        self.codeAgentEnabledFeatures = codeAgentEnabledFeatures
    }

    private enum CodingKeys: String, CodingKey {
        case modelsRootPath, defaultChatImageModelID, chatMessageWaitSeconds
        case codeAgentWorkingDirectoryPath, codeAgentAllowFullDiskAccess
        case codeAgentPermissionLevel, codeAgentEnabledFeatures
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
        chatMessageWaitSeconds = try container.decodeIfPresent(Double.self, forKey: .chatMessageWaitSeconds) ?? 10
        codeAgentWorkingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .codeAgentWorkingDirectoryPath)
        codeAgentAllowFullDiskAccess = try container.decodeIfPresent(Bool.self, forKey: .codeAgentAllowFullDiskAccess) ?? false
        codeAgentPermissionLevel = try container.decodeIfPresent(CodeAgentPermissionLevel.self, forKey: .codeAgentPermissionLevel) ?? .manual
        codeAgentEnabledFeatures = try container.decodeIfPresent(Set<CodeAgentFeature>.self, forKey: .codeAgentEnabledFeatures) ?? []
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
