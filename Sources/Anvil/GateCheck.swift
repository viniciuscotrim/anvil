import Foundation
import AnvilCore

/// Headless verification for the phase gates in docs/build-brief.md.
/// Run with `swift run Anvil -- --phase2-gate` (see main.swift — this
/// never creates a SwiftUI window). Prints the resulting model registry
/// as JSON to stdout and exits, so each gate is confirmed by an
/// inspectable artifact rather than "it looked fine in the UI."
enum GateCheck {
    private static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    /// Cold download of one model + import of one already-on-disk model
    /// folder, both landing in the same registry. Configurable via env
    /// vars so a real run can target a real pre-existing directory
    /// without hardcoding a path into the binary.
    static func runPhase2GateIfRequested() async -> Bool {
        guard CommandLine.arguments.contains("--phase2-gate") else { return false }

        let env = ProcessInfo.processInfo.environment
        let downloadRepoID = env["ANVIL_GATE_DOWNLOAD_REPO"] ?? "mlx-community/SmolLM2-135M-Instruct-8bit"

        let registry = ModelRegistry()
        let python = PythonEnvironment()
        let downloader = ModelDownloader(registry: registry, python: python)
        let importer = ModelImporter(registry: registry)

        do {
            if !(await python.isPackageInstalled("huggingface_hub")) {
                log("Setting up model browser…")
                try await python.pipInstall(["huggingface_hub"])
            }

            log("Downloading \(downloadRepoID) from a cold state…")
            let downloaded = try await downloader.download(repoID: downloadRepoID) { log($0) }
            log("Downloaded to \(downloaded.localPath)")

            if let importPath = env["ANVIL_GATE_IMPORT_PATH"] {
                log("Importing existing model folder at \(importPath)…")
                let imported = try await importer.importModel(at: URL(fileURLWithPath: importPath))
                log("Imported without re-downloading: \(imported.localPath)")
            } else {
                log("ANVIL_GATE_IMPORT_PATH not set — skipping the import half of the gate")
            }
        } catch {
            log("Gate check failed: \(error.localizedDescription)")
        }

        let entries = await registry.all()
        if let data = try? JSONEncoder.anvil.encode(entries), let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("[]")
        }

        return true
    }
}
