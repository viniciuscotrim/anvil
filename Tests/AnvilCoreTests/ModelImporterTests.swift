import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelImporter")
struct ModelImporterTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func importsADirectoryWithConfigJSON() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        let entry = try await importer.importModel(at: dir)

        #expect(entry.localPath == dir.standardizedFileURL.path)
        if case .imported(let originalPath) = entry.source {
            #expect(originalPath == dir.standardizedFileURL.path)
        } else {
            Issue.record("expected .imported source")
        }
    }

    @Test
    func importsADirectoryWithOnlySafetensors() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("model.safetensors"))

        let registry = ModelRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        _ = try await importer.importModel(at: dir)
        let all = await registry.all()
        #expect(all.count == 1)
    }

    @Test
    func rejectsADirectoryWithNoModelFiles() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        await #expect(throws: ModelError.self) {
            try await importer.importModel(at: dir)
        }
    }

    @Test
    func importFolderRegistersEverySubfolderThatLooksLikeAModel() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let modelA = root.appendingPathComponent("model-a", isDirectory: true)
        let modelB = root.appendingPathComponent("model-b", isDirectory: true)
        let notAModel = root.appendingPathComponent("readme-only", isDirectory: true)
        try FileManager.default.createDirectory(at: modelA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notAModel, withIntermediateDirectories: true)
        try "{}".write(to: modelA.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try Data().write(to: modelB.appendingPathComponent("weights.safetensors"))
        try "hi".write(to: notAModel.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        let imported = try await importer.importFolder(at: root)

        #expect(imported.count == 2)
        let all = await registry.all()
        #expect(Set(all.map(\.displayName)) == ["model-a", "model-b"])
    }

    @Test
    func importFolderFindsModelsNestedTwoLevelsDeepLikeAnHFNamespaceRepoLayout() async throws {
        // A real reported bug: a one-level-only scan found nothing in a
        // real models folder, because `snapshot_download`/`git clone`
        // lay files out as `<namespace>/<repo>/…`, not flat.
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("Some-Model-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "{}".write(to: nested.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        let imported = try await importer.importFolder(at: root)

        #expect(imported.count == 1)
        #expect(imported.first?.localPath == nested.standardizedFileURL.path)
    }

    @Test
    func importFolderDoesNotDescendIntoAModelsOwnComponentSubdirectories() async throws {
        // A diffusion pipeline's `transformer/`/`vae/` subfolders must
        // never be registered as their own separate "models".
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = root.appendingPathComponent("flux-model", isDirectory: true)
        let transformer = pipeline.appendingPathComponent("transformer", isDirectory: true)
        let vae = pipeline.appendingPathComponent("vae", isDirectory: true)
        try FileManager.default.createDirectory(at: transformer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vae, withIntermediateDirectories: true)
        try "{}".write(to: transformer.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: root.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        let imported = try await importer.importFolder(at: root)

        #expect(imported.count == 1)
        #expect(imported.first?.localPath == pipeline.standardizedFileURL.path)
    }

    @Test
    func importFolderImportsTheFolderItselfWhenItIsDirectlyAModel() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        let imported = try await importer.importFolder(at: dir)

        #expect(imported.count == 1)
        #expect(imported.first?.localPath == dir.standardizedFileURL.path)
    }

    @Test
    func rejectsAPathThatIsNotADirectory() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("config.json")
        try "{}".write(to: filePath, atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: dir.appendingPathComponent("registry.json"))
        let importer = ModelImporter(registry: registry)

        await #expect(throws: ModelError.self) {
            try await importer.importModel(at: filePath)
        }
    }
}
