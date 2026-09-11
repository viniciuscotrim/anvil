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
