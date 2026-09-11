import Foundation

/// A tiny persisted key-value store for app-level preferences that
/// don't belong on any one model/thread/profile — today just the
/// optional custom folder for downloaded/imported models. One JSON
/// file, same pattern as the other stores, but a plain struct (not an
/// actor) since it's only ever touched from the main actor UI and
/// writes are small and infrequent — callers just re-`load()`/`save()`
/// around each change instead of holding a long-lived instance.
public struct AppSettings: Codable, Sendable, Equatable {
    /// Where new downloads land and where "scan for existing models"
    /// looks — nil means the default, `RuntimePaths.modelsDirectory`.
    public var modelsRootPath: String?

    public init(modelsRootPath: String? = nil) {
        self.modelsRootPath = modelsRootPath
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
}
