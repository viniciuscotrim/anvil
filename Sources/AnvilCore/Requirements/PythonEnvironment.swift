import Foundation

// macOS-only: shells out via ProcessRunner (Process-based) to the
// app's private Python venv — no such thing exists on iOS.
#if os(macOS)

/// The single private Python venv Anvil's backend runs in, managed
/// entirely through the bootstrapped `uv` binary. One venv, grown
/// incrementally as the user's choices require more packages —
/// never reinstalled from scratch.
public struct PythonEnvironment: Sendable {
    public init() {}

    public var venvPython: URL {
        RuntimePaths.venvDirectory.appendingPathComponent("bin/python3")
    }

    public func venvExists() -> Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path)
    }

    public func createVenvIfNeeded(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        guard !venvExists() else { return }
        guard UVBootstrapper().isInstalled() else {
            throw DependencyError.installFailed("uv must be installed before the venv can be created")
        }
        try RuntimePaths.ensureBaseDirectoriesExist()
        onProgress(InstallProgress(message: "Setting up Python environment…"))
        _ = try await ProcessRunner.run(
            executable: RuntimePaths.uvBinary,
            arguments: ["venv", RuntimePaths.venvDirectory.path, "--python", "3.12"]
        )
        guard venvExists() else {
            throw DependencyError.installFailed("venv creation did not produce a python interpreter")
        }
    }

    /// Checks by import name (e.g. "mlx_lm"), not pip package name (e.g. "mlx-lm").
    public func isPackageInstalled(_ importName: String) async -> Bool {
        guard venvExists() else { return false }
        do {
            _ = try await ProcessRunner.run(
                executable: venvPython,
                arguments: [
                    "-c",
                    "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec(\"\(importName)\") else 1)"
                ]
            )
            return true
        } catch {
            return false
        }
    }

    public func pipInstall(_ packages: [String], onOutputLine: (@Sendable (String) -> Void)? = nil) async throws {
        try await createVenvIfNeeded(onProgress: { _ in })
        _ = try await ProcessRunner.run(
            executable: RuntimePaths.uvBinary,
            arguments: ["pip", "install", "--python", venvPython.path] + packages,
            onOutputLine: onOutputLine
        )
    }
}

#endif
