import Foundation
import CryptoKit

// macOS-only: bootstraps `uv` and a private Python venv via
// ProcessRunner (Process-based) — no subprocess execution or
// Python venv concept exists on iOS.
#if os(macOS)

/// Bootstraps `uv` (the Python package/venv manager) as a private binary
/// under `RuntimePaths.binDirectory` — never installed globally, never
/// touching the user's shell profile or PATH.
///
/// Fetches the prebuilt binary directly from `uv`'s GitHub releases
/// (the "latest" redirect, so it always tracks the current release
/// without a hardcoded version) and verifies it against the published
/// sha256 before anything is executed. This is the app's one and only
/// network-bootstrap step; everything after this point runs through
/// `uv` itself.
public struct UVBootstrapper: Sendable {
    public init() {}

    private var releaseAssetName: String {
        #if arch(arm64)
        return "uv-aarch64-apple-darwin.tar.gz"
        #else
        return "uv-x86_64-apple-darwin.tar.gz"
        #endif
    }

    private var downloadURL: URL {
        URL(string: "https://github.com/astral-sh/uv/releases/latest/download/\(releaseAssetName)")!
    }

    private var checksumURL: URL {
        URL(string: "https://github.com/astral-sh/uv/releases/latest/download/\(releaseAssetName).sha256")!
    }

    public func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: RuntimePaths.uvBinary.path)
    }

    public func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        if isInstalled() { return }
        try RuntimePaths.ensureBaseDirectoriesExist()

        onProgress(InstallProgress(message: "Downloading Python runtime manager…"))
        let (archiveData, checksumText) = try await downloadArchiveAndChecksum()

        onProgress(InstallProgress(message: "Verifying download…"))
        try verify(archiveData, against: checksumText)

        onProgress(InstallProgress(message: "Installing runtime manager…"))
        try await extractUVBinary(from: archiveData)

        guard isInstalled() else {
            throw DependencyError.installFailed("uv binary missing after extraction")
        }
        onProgress(InstallProgress(message: "Runtime manager ready", fractionComplete: 1.0))
    }

    private func downloadArchiveAndChecksum() async throws -> (Data, String) {
        async let archive = URLSession.shared.data(from: downloadURL)
        async let checksum = URLSession.shared.data(from: checksumURL)
        let (archiveData, archiveResponse) = try await archive
        let (checksumData, _) = try await checksum

        guard let http = archiveResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DependencyError.installFailed("Unexpected response downloading uv")
        }
        guard let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw DependencyError.installFailed("Could not read uv checksum file")
        }
        return (archiveData, checksumText)
    }

    private func verify(_ data: Data, against checksumFileContents: String) throws {
        // Format: "<sha256hex>  <filename>"
        guard let expectedHex = checksumFileContents
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first else {
            throw DependencyError.installFailed("Malformed uv checksum file")
        }
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex == expectedHex.lowercased() else {
            throw DependencyError.installFailed("Checksum mismatch for uv download — refusing to install")
        }
    }

    private func extractUVBinary(from archiveData: Data) async throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let archivePath = workDir.appendingPathComponent("uv.tar.gz")
        try archiveData.write(to: archivePath)

        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archivePath.path, "-C", workDir.path]
        )

        guard let found = try findFile(named: "uv", under: workDir) else {
            throw DependencyError.installFailed("uv binary not found inside downloaded archive")
        }

        if fm.fileExists(atPath: RuntimePaths.uvBinary.path) {
            try fm.removeItem(at: RuntimePaths.uvBinary)
        }
        try fm.copyItem(at: found, to: RuntimePaths.uvBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: RuntimePaths.uvBinary.path)
    }

    private func findFile(named name: String, under directory: URL) throws -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                return url
            }
        }
        return nil
    }
}

#endif
