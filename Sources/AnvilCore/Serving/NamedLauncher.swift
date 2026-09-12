import Foundation
import Darwin

// macOS-only: this whole file is built around `Foundation.Process`,
// which doesn't exist on iOS at all (confirmed for real — even a
// bare `Process()` reference inside a function body fails to
// typecheck for an iOS target). The iOS port needs a genuinely
// different mechanism here (native `mlx-swift` inference in-process,
// not a subprocess server) rather than a port of this approach.
#if os(macOS)

/// Gives each loaded model's subprocess a real, distinct name in
/// Activity Monitor ("Anvil - <model>", truncated to the kernel's
/// 16-character process-name limit) instead of a generic "Python"
/// shared by every model and indistinguishable from anything else
/// Python-based running on the Mac.
///
/// The venv's own `python3` is a framework build that unconditionally
/// re-execs itself into a fixed binary — `Python.app/Contents/MacOS/Python`
/// — needed for Metal/GPU access. A first attempt at this fix invoked
/// that real binary through a **symlink** named after the model, on the
/// theory that skipping straight to it would avoid any further renaming.
/// Real testing (`ps -o ucomm=`, matching what Activity Monitor's Process
/// Name column actually reads) proved that wrong: macOS sets a process's
/// kernel-level name (`p_comm`) from the *resolved target* of whatever
/// was executed, not the symlink used to reach it — so every model kept
/// showing up as plain "Python" no matter what the symlink was called.
/// A real **file copy** of that binary (it's a ~33KB stub, cheap to
/// duplicate per model) behaves differently: there's no symlink
/// indirection to resolve through, so the copy's own filename becomes
/// its process name. Validated for real: a copy placed in `venv/bin/`
/// under a custom name resolves `sys.prefix` to this venv, imports
/// `mlx.core` and gets `Device(gpu, 0)` (Metal still works, unaffected
/// by the stub living outside its original bundle — it loads its
/// framework dylib via absolute paths, not bundle-relative ones), and
/// `ps -o ucomm=` shows the custom name throughout its run.
public actor NamedLauncher {
    public static let shared = NamedLauncher()

    private static let namePrefix = "Anvil - "
    private var cachedRealInterpreterPath: URL?

    private init() {}

    /// Creates (or replaces) a real copy — not a symlink; see the type's
    /// doc comment for why that distinction is the whole fix — under
    /// `venv/bin/` that runs as `displayName` in Activity Monitor.
    /// Placed inside `venv/bin/` so Python's own venv detection — based
    /// on where it was invoked from — still finds `pyvenv.cfg` and loads
    /// this venv's site-packages.
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
            try fm.copyItem(at: realBinary, to: launcherURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        } catch {
            try? fm.removeItem(at: launcherURL)
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

#endif
