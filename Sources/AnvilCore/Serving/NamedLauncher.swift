import Foundation
import Darwin

/// Gives each loaded model's subprocess a real, distinct name in
/// Activity Monitor ("Anvil - <model>") instead of a generic "Python"
/// shared by every model and indistinguishable from anything else
/// Python-based running on the Mac.
///
/// The venv's own `python3` is a framework build that unconditionally
/// re-execs itself into a fixed binary — `Python.app/Contents/MacOS/Python`
/// — needed for Metal/GPU access, so simply renaming the invocation
/// doesn't work: the interpreter's own startup code overrides it before
/// we get a say. `sys.executable` doesn't reveal that real path either
/// (it just echoes back whatever it was invoked with). The actual fix:
/// ask the kernel what a probe process is *really* running as via
/// `proc_pidpath` — an unconditional runtime decision baked into the
/// compiled interpreter, not discoverable by following symlinks — then
/// invoke that real binary directly through our own symlink. Once
/// already there, there's nothing left for it to re-exec into.
public actor NamedLauncher {
    public static let shared = NamedLauncher()

    private static let namePrefix = "Anvil - "
    private var cachedRealInterpreterPath: URL?

    private init() {}

    /// Creates (or replaces) a symlink under `venv/bin/` that runs as
    /// `displayName` in Activity Monitor. Placed inside `venv/bin/` so
    /// Python's own venv detection — based on where it was invoked
    /// from, not full path resolution — still finds `pyvenv.cfg` and
    /// loads this venv's site-packages.
    public func makeLauncher(displayName: String) async -> URL {
        let venvPython = RuntimePaths.venvDirectory.appendingPathComponent("bin/python3")
        guard let realBinary = await resolveRealInterpreterPath() else {
            // Falls back to the plain venv python — loses the custom
            // name but keeps serving working if the probe ever fails.
            return venvPython
        }

        let launcherURL = RuntimePaths.venvDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(Self.sanitize(displayName))

        let fm = FileManager.default
        if fm.fileExists(atPath: launcherURL.path) {
            try? fm.removeItem(at: launcherURL)
        }
        do {
            try fm.createSymbolicLink(at: launcherURL, withDestinationURL: realBinary)
        } catch {
            return venvPython
        }
        return launcherURL
    }

    public func removeLauncher(at url: URL) {
        guard url.lastPathComponent.hasPrefix(Self.namePrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes any launcher symlinks left behind by a previous run that
    /// didn't shut down cleanly (a crash, a force-quit). Safe to call
    /// any time — each one gets recreated the next time that model
    /// loads.
    public func cleanupStaleLaunchers() {
        let binDirectory = RuntimePaths.venvDirectory.appendingPathComponent("bin", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.lastPathComponent.hasPrefix(Self.namePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Runs the venv's python3 briefly and asks the kernel what it's
    /// actually running as, post any internal re-exec — cached, since
    /// it's the same answer for every model loaded from this venv.
    private func resolveRealInterpreterPath() async -> URL? {
        if let cachedRealInterpreterPath {
            return cachedRealInterpreterPath
        }

        let python = RuntimePaths.venvDirectory.appendingPathComponent("bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }

        let proc = Process()
        proc.executableURL = python
        proc.arguments = ["-c", "import time; time.sleep(5)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return nil }
        defer { proc.terminate() }

        // Give it a moment to finish any internal re-exec before asking.
        try? await Task.sleep(nanoseconds: 150_000_000)

        var buffer = [Int8](repeating: 0, count: 4096)
        let length = proc_pidpath(proc.processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }

        let resolved = URL(fileURLWithPath: String(cString: buffer))
        cachedRealInterpreterPath = resolved
        return resolved
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(cleaned.prefix(64))
        return namePrefix + (truncated.isEmpty ? "model" : truncated)
    }
}
