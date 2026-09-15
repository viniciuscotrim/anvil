import Foundation

/// A fresh, empty temporary directory — shared by any test that needs
/// real files on disk (`ModelImporterTests`/`ModelKindDetectorTests`
/// each used to define this identically). Callers are responsible for
/// cleaning up (`defer { try? FileManager.default.removeItem(at:) }`),
/// same as before.
func makeTempDirectory(name: String = "anvil-tests") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
