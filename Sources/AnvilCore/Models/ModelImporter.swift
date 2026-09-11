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

    /// Scans a folder's immediate subdirectories and registers every one
    /// that looks like a model — the mechanism behind "choose a models
    /// folder": pick a folder full of models downloaded outside Anvil
    /// (an old oMLX/Draw Things models directory, say) and this makes
    /// them all show up in "Registered models" without moving a byte.
    /// A subdirectory that's already registered (by path) is
    /// re-registered in place — same path, so `upsert` just refreshes
    /// its metadata rather than duplicating it — one that doesn't look
    /// like a model is silently skipped, not an error: a models folder
    /// legitimately has non-model clutter in it sometimes.
    @discardableResult
    public func importFolder(at path: URL) async throws -> [ModelEntry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelError.importFailed("\(path.path) is not a directory")
        }

        // The folder itself might directly *be* one model (its own
        // files at the top level) rather than a folder *of* models —
        // handle that case too instead of finding nothing.
        if Self.looksLikeAModel(at: path) {
            return [try await importModel(at: path)]
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var imported: [ModelEntry] = []
        for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var entryIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory),
                  entryIsDirectory.boolValue,
                  Self.looksLikeAModel(at: entry) else { continue }
            if let registered = try? await importModel(at: entry) {
                imported.append(registered)
            }
        }
        return imported
    }

    static func looksLikeAModel(at path: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
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
