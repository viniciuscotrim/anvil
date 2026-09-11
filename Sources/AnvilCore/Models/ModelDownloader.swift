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

    /// Where `download(repoID:)` will place this repo's files — exposed
    /// so a caller (the "Stop download" button) can find and delete a
    /// partially-downloaded directory without duplicating this logic or
    /// waiting for `download` to return a `ModelEntry` it never will if
    /// cancelled.
    public static func destinationDirectory(forRepoID repoID: String) -> URL {
        AppSettings.load().effectiveModelsRoot.appendingPathComponent(sanitize(repoID), isDirectory: true)
    }

    /// Cooperatively cancellable — cancelling the calling `Task` sends
    /// the underlying `snapshot_download` process `SIGTERM` and this
    /// throws `CancellationError` (see `ProcessRunner`). The caller
    /// decides what "cancelled" means: leave the partial directory in
    /// place (pause — Hugging Face's own resumable-download support
    /// picks up where it left off next time) or delete it (stop).
    ///
    /// `knownFilePaths`, when the caller already has a repo's file list
    /// (a search result's own `siblings`, typically — no extra API call
    /// needed), skips downloading a real, reported waste: some repos
    /// ship the *same* weights twice — once as component subfolders
    /// (`transformer/`, `vae/`, …, the diffusers-pipeline shape `mflux`
    /// actually loads) and *again* as a redundant flat root-level file
    /// for single-file-loading tools that don't need this repo's
    /// pipeline structure at all. Confirmed on a real repo
    /// (`black-forest-labs/FLUX.2-klein-4B`): a 7.8GB root-level
    /// `flux-2-klein-4b.safetensors` duplicating
    /// `transformer/diffusion_pytorch_model.safetensors` byte-for-byte
    /// in size, on top of the real ~16GB the pipeline actually needs —
    /// bringing a download that only needed to be ~16GB up to ~24GB for
    /// nothing. Only ever skips a *root-level* weight file, and only
    /// when `model_index.json` is present (a real pipeline confirmed,
    /// not a guess) — never touches anything inside a component
    /// subfolder.
    @discardableResult
    public func download(
        repoID: String,
        revision: String = "main",
        knownFilePaths: [String]? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ModelEntry {
        guard python.venvExists() else {
            throw ModelError.downloadFailed("Python environment isn't set up yet — install the model browser first")
        }

        let destination = Self.destinationDirectory(forRepoID: repoID)
        let ignorePatterns = Self.redundantRootLevelWeightFiles(in: knownFilePaths ?? [])
        if !ignorePatterns.isEmpty {
            onProgress?("Skipping \(ignorePatterns.count) redundant file(s) already covered by this repo's own pipeline folders…")
        }
        let ignorePatternsJSON = (try? String(data: JSONEncoder().encode(ignorePatterns), encoding: .utf8)) ?? "[]"

        onProgress?("Downloading \(repoID)…")

        let script = """
        import json
        import os
        import sys
        from huggingface_hub import snapshot_download
        ignore_patterns = json.loads(sys.argv[4]) or None
        path = snapshot_download(
            repo_id=sys.argv[1],
            revision=sys.argv[2],
            local_dir=sys.argv[3],
            token=os.environ.get("HF_TOKEN") or None,
            ignore_patterns=ignore_patterns,
        )
        print(path)
        """

        // Passing `environment:` replaces the whole child environment
        // (Foundation's `Process` only inherits it when left nil), so a
        // token means starting from a real copy of ours, not a bare
        // `["HF_TOKEN": …]` that would also strip PATH/HOME and break
        // the interpreter.
        var environment: [String: String]?
        if let token = HFTokenStore.load(), !token.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env["HF_TOKEN"] = token
            environment = env
        }

        let output: String
        do {
            output = try await ProcessRunner.run(
                executable: python.venvPython,
                arguments: ["-c", script, repoID, revision, destination.path, ignorePatternsJSON],
                environment: environment,
                onOutputLine: onProgress
            )
        } catch is CancellationError {
            throw CancellationError()
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

    /// Root-level (no `/` in the path) weight files to skip — only when
    /// `model_index.json` is present, confirming a real diffusers
    /// pipeline exists in this repo's component subfolders, so a
    /// same-named-pattern file sitting loose at the top level is a
    /// redundant duplicate for a different tool, not something this
    /// pipeline itself needs. See `download`'s doc comment for the real
    /// case (and real byte counts) this was found on.
    static func redundantRootLevelWeightFiles(in filePaths: [String]) -> [String] {
        guard filePaths.contains(where: { $0.caseInsensitiveCompare("model_index.json") == .orderedSame }) else {
            return []
        }
        let weightExtensions: Set<String> = ["safetensors", "bin", "ckpt", "pt", "gguf"]
        return filePaths.filter { path in
            !path.contains("/") && weightExtensions.contains((path as NSString).pathExtension.lowercased())
        }
    }
}
