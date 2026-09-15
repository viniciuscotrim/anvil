import Foundation

/// Registers an already-existing model folder — today's oMLX model
/// directory, say — without moving, copying, or re-downloading a single
/// byte of it. Registration just means: verify it looks like a model,
/// then record its path.
public struct ModelImporter: Sendable {
    private let registry: ModelRegistry

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    @discardableResult
    public func importModel(at path: URL) async throws -> ModelEntry {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelError.importFailed("\(path.path) is not a directory")
        }

        guard Self.looksLikeAModel(at: path) else {
            throw ModelError.importFailed(
                "No recognizable model files (config.json, *.safetensors, or *.gguf) found in \(path.lastPathComponent)"
            )
        }

        let entry = ModelEntry(
            id: "imported:\(path.standardizedFileURL.path)",
            displayName: path.lastPathComponent,
            source: .imported(originalPath: path.standardizedFileURL.path),
            localPath: path.standardizedFileURL.path,
            sizeBytes: DirectorySize.of(path),
            kind: ModelKindDetector.detect(at: path)
        )
        return try await registry.upsert(entry)
    }

    /// Scans a folder — recursively, not just its immediate children —
    /// and registers every subdirectory that looks like a model. Real
    /// models folders are almost always laid out `<namespace>/<repo>/…`
    /// (mirroring Hugging Face's own org/repo shape, which is exactly
    /// what `snapshot_download`/`git clone` produce), so a one-level
    /// scan found nothing in a folder full of real models — a real,
    /// reported bug. Recursion stops the moment a directory looks like a
    /// model itself (never descends into a model's own component
    /// subfolders — `transformer/`, `vae/`, and friends for a diffusion
    /// pipeline), and is bounded to a sane depth so a stray symlink loop
    /// or an enormous unrelated folder can't run away.
    ///
    /// A directory that's already registered gets its metadata
    /// refreshed in place rather than duplicated — including when it's
    /// registered under a *different* id than this scan would generate
    /// (a real, reported bug: a model downloaded through search first,
    /// then swept up again by a later folder scan, ended up listed
    /// twice — once under its stable Hugging Face repo id, once under a
    /// second, path-derived "imported:" id for the exact same files —
    /// because the old check only mattered once `upsert` had already
    /// decided two ids were different entries). Matching is by
    /// `localPath`, checked against the registry directly, before any
    /// id is ever generated. One that doesn't look like a model
    /// anywhere below it is silently skipped, not an error: a models
    /// folder legitimately has non-model clutter in it sometimes.
    @discardableResult
    public func importFolder(at path: URL, maxDepth: Int = 4) async throws -> [ModelEntry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelError.importFailed("\(path.path) is not a directory")
        }

        let modelDirectories = Self.findModelDirectories(under: path, remainingDepth: maxDepth)
        // Built with a plain loop rather than `Dictionary(uniqueKeysWithValues:)`:
        // resolving symlinks can make two already-registered entries collide
        // on the same real path (exactly the case `deduplicateByLocalPath`
        // exists to clean up), which would otherwise crash here.
        var existingByPath: [String: ModelEntry] = [:]
        for entry in await registry.all() {
            existingByPath[URL(fileURLWithPath: entry.localPath).canonicalModelPathKey] = entry
        }

        var imported: [ModelEntry] = []
        for directory in modelDirectories.sorted(by: { $0.path < $1.path }) {
            let standardizedPath = directory.canonicalModelPathKey
            if let existing = existingByPath[standardizedPath] {
                var refreshed = existing
                refreshed.sizeBytes = DirectorySize.of(directory)
                refreshed.kind = ModelKindDetector.detect(at: directory)
                if let saved = try? await registry.upsert(refreshed) {
                    imported.append(saved)
                }
                continue
            }
            if let registered = try? await importModel(at: directory) {
                imported.append(registered)
            }
        }
        return imported
    }

    /// Depth-first search for model directories under `root` (`root`
    /// itself included). Never recurses into a directory once it's
    /// already been identified as a model. Lists each directory's
    /// contents exactly once — both the "does this look like a model"
    /// check and the recursion into subdirectories used to list the
    /// same directory separately, doubling the filesystem calls across
    /// every node a folder-wide scan visits.
    private static func findModelDirectories(under root: URL, remainingDepth: Int) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            // `root` itself couldn't be listed (permissions, or it's not
            // a directory at all) — it might still qualify as a model
            // some other way `looksLikeAModel(at:)` alone can check.
            return looksLikeAModel(at: root) ? [root] : []
        }
        if Self.looksLikeAModel(contents: contents) {
            return [root]
        }
        guard remainingDepth > 0 else { return [] }

        var found: [URL] = []
        for entry in contents {
            // Skip hidden entries (`.cache`, `.git`, `.DS_Store`, …) —
            // never anything a scan like this should surface.
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }
            var entryIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory),
                  entryIsDirectory.boolValue else { continue }
            found += findModelDirectories(under: entry, remainingDepth: remainingDepth - 1)
        }
        return found
    }

    static func looksLikeAModel(at path: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return looksLikeAModel(contents: contents)
    }

    private static func looksLikeAModel(contents: [URL]) -> Bool {
        let names = Set(contents.map(\.lastPathComponent))

        if names.contains("config.json") || names.contains("model_index.json") {
            return true
        }
        // A diffusion pipeline (Flux and friends): weights live inside
        // component subdirectories rather than flat at the top level.
        if names.contains("transformer") && names.contains("vae") {
            return true
        }
        return contents.contains { ["safetensors", "gguf"].contains($0.pathExtension.lowercased()) }
    }
}
