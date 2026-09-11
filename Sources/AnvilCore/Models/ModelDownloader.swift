import Foundation

/// Downloads a model's files via `huggingface_hub.snapshot_download`
/// (through the app's private Python venv) and registers the result.
/// Reuses whatever `huggingface_hub` already cached — a repeat download
/// of the same repo/revision only fetches what changed.
public struct ModelDownloader: Sendable {
    private let python: PythonEnvironment
    private let registry: ModelRegistry

    public init(registry: ModelRegistry, python: PythonEnvironment = PythonEnvironment()) {
        self.registry = registry
        self.python = python
    }

    @discardableResult
    public func download(
        repoID: String,
        revision: String = "main",
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ModelEntry {
        guard python.venvExists() else {
            throw ModelError.downloadFailed("Python environment isn't set up yet — install the model browser first")
        }

        let destination = RuntimePaths.modelsDirectory
            .appendingPathComponent(Self.sanitize(repoID), isDirectory: true)

        onProgress?("Downloading \(repoID)…")

        let script = """
        import sys
        from huggingface_hub import snapshot_download
        path = snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
        print(path)
        """

        let output: String
        do {
            output = try await ProcessRunner.run(
                executable: python.venvPython,
                arguments: ["-c", script, repoID, revision, destination.path],
                onOutputLine: onProgress
            )
        } catch {
            throw ModelError.downloadFailed(error.localizedDescription)
        }

        guard let localPath = output
            .split(separator: "\n")
            .last
            .map(String.init),
            FileManager.default.fileExists(atPath: localPath) else {
            throw ModelError.downloadFailed("snapshot_download did not produce a usable local path")
        }

        let localURL = URL(fileURLWithPath: localPath)
        let entry = ModelEntry(
            id: repoID,
            displayName: repoID,
            source: .huggingFace(repoID: repoID, revision: revision),
            localPath: localPath,
            sizeBytes: DirectorySize.of(localURL),
            kind: ModelKindDetector.detect(at: localURL)
        )
        return try await registry.upsert(entry)
    }

    private static func sanitize(_ repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }
}
