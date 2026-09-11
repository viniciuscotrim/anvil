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
