import Foundation

// macOS-only: terminal commands go through `ProcessRunner`, which is
// built around `Foundation.Process` — doesn't exist on iOS at all (see
// that file's own header comment). File read/write/list are pure
// `FileManager` and could run on iOS too, but the Code agent itself is
// a Mac-only feature for now (no iOS UI drives this), so the whole
// runner stays behind this gate rather than splitting file ops out.
#if os(macOS)

public enum CodeAgentError: Error, LocalizedError, Sendable {
    case noWorkingDirectory
    case pathEscapesWorkingDirectory(String)
    case fileNotFound(String)
    case notAFile(String)

    public var errorDescription: String? {
        switch self {
        case .noWorkingDirectory:
            return "No working folder is set — pick one in the Code tab's settings first."
        case .pathEscapesWorkingDirectory(let path):
            return "\"\(path)\" is outside the working folder. Turn on full-disk access in Settings to allow this."
        case .fileNotFound(let path):
            return "No file at \"\(path)\"."
        case .notAFile(let path):
            return "\"\(path)\" is a directory, not a file."
        }
    }
}

/// Executes the Code agent's tools for real — file read/write/list via
/// `FileManager`, shell commands via the same `ProcessRunner` the
/// Requirements layer already uses to drive `uv`/Python. Every call is
/// confined to `workingDirectory` unless `allowFullDiskAccess` is true:
/// `resolve` rejects a path that would escape it, whether via an
/// absolute path, a `..` segment, or a symlink (checked via
/// `resolvingSymlinksInPath`, not just the lexical path) pointing
/// somewhere the user never agreed to.
public struct CodeAgentToolRunner: Sendable {
    public let workingDirectory: URL?
    public let allowFullDiskAccess: Bool

    public init(workingDirectory: URL?, allowFullDiskAccess: Bool) {
        self.workingDirectory = workingDirectory
        self.allowFullDiskAccess = allowFullDiskAccess
    }

    public func readFile(atPath path: String) throws -> String {
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CodeAgentError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw CodeAgentError.notAFile(path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Sorted, one name per line — a trailing `/` marks a subdirectory,
    /// the same convention `ls -F` uses.
    public func listDirectory(atPath path: String) throws -> [String] {
        let url = try resolve(path)
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])
        return contents
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { item in
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDirectory ? "\(item.lastPathComponent)/" : item.lastPathComponent
            }
    }

    @discardableResult
    public func writeFile(atPath path: String, content: String) throws -> URL {
        let url = try resolve(path)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Combined stdout+stderr and the real exit code — a non-zero exit
    /// is reported back to the caller (and, from there, to the model)
    /// rather than thrown, since "the command ran and failed" is
    /// meaningfully different from "the command couldn't be run at all"
    /// (a bad working directory, `/bin/zsh` missing, …).
    public func runTerminalCommand(_ command: String) async throws -> (output: String, exitCode: Int32) {
        let directory = try resolvedWorkingDirectoryForCommands()
        do {
            let output = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-lc", command],
                currentDirectory: directory
            )
            return (output, 0)
        } catch ProcessRunnerError.nonZeroExit(let exitCode, let output) {
            return (output, exitCode)
        }
    }

    // MARK: - Path confinement

    private func resolvedWorkingDirectoryForCommands() throws -> URL {
        if let workingDirectory { return workingDirectory }
        guard allowFullDiskAccess else { throw CodeAgentError.noWorkingDirectory }
        // Full-disk access with no folder chosen still needs *some*
        // directory to run commands from — the user's home, the same
        // reasonable default a fresh Terminal tab opens in.
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func resolve(_ path: String) throws -> URL {
        if allowFullDiskAccess {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path)
            }
            let base = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }

        guard let workingDirectory else { throw CodeAgentError.noWorkingDirectory }
        let candidate = URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
        let root = workingDirectory.resolvingSymlinksInPath().path
        // A not-yet-existing write target has nothing to resolve
        // symlinks against — only its lexical (already `..`-collapsed)
        // path is checked in that case; anything that already exists
        // (a read, a listing, or overwriting a file) is checked against
        // where it *really* points.
        let checkedPath = FileManager.default.fileExists(atPath: candidate.path)
            ? candidate.resolvingSymlinksInPath().path
            : candidate.path

        guard checkedPath == root || checkedPath.hasPrefix(root + "/") else {
            throw CodeAgentError.pathEscapesWorkingDirectory(path)
        }
        return candidate
    }
}

#endif
