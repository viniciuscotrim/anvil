import Foundation

/// Where Anvil's private runtime lives. Nothing here ever touches the
/// user's system Python, Homebrew, or shell profile — it's all scoped
/// under this app's own Application Support directory.
public enum RuntimePaths {
    public static let appSupportDirName = "Anvil"

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return base.appendingPathComponent(appSupportDirName, isDirectory: true)
    }

    /// Private, non-PATH-polluting home for binaries Anvil bootstraps itself (e.g. `uv`).
    public static var binDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    /// The single Python virtual environment Anvil manages for its backend.
    public static var venvDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    public static var uvBinary: URL {
        binDirectory.appendingPathComponent("uv")
    }

    public static var logsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Where imported/downloaded model weights are registered (Phase 2).
    public static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    public static func ensureBaseDirectoriesExist() throws {
        let fm = FileManager.default
        for dir in [applicationSupportDirectory, binDirectory, venvDirectory, logsDirectory, modelsDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
