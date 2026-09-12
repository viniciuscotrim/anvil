import Foundation

// macOS-only: this whole file is built around `Foundation.Process`,
// which doesn't exist on iOS at all (confirmed for real — even a
// bare `Process()` reference inside a function body fails to
// typecheck for an iOS target). The iOS port needs a genuinely
// different mechanism here (native `mlx-swift` inference in-process,
// not a subprocess server) rather than a port of this approach.
#if os(macOS)

/// Guarantees a spawned server subprocess dies with Anvil no matter how
/// Anvil itself goes away — not just a clean Quit (already handled by
/// `AppDelegate.applicationShouldTerminate`), but a force-quit, a
/// crash, or `kill -9`, none of which run a single line of Anvil's own
/// shutdown code. That gap is exactly how a real orphaned process was
/// found during development: a model server whose app had already
/// quit, still resident, still holding several gigabytes, hours later.
///
/// A tiny shell process, spawned as Anvil's direct child, polls its own
/// parent PID (`ps -o ppid=`) — when Anvil dies for any reason, the OS
/// reparents this watchdog to launchd (ppid becomes `1`) within moments,
/// and it kills the server it's watching. Verified for real: spawned a
/// fake parent + this watchdog + a target process, `kill -9`'d the fake
/// parent (no cleanup code ran, exactly like a crash), and confirmed
/// the target was killed within a couple of seconds.
enum ProcessWatchdog {
    /// Fire-and-forget: not retained or tracked further. It exits on
    /// its own once the process it watches stops (the normal path,
    /// noticed within one poll interval) or once it detects Anvil is
    /// gone and kills it itself.
    static func attach(toPID pid: pid_t) {
        guard let scriptURL = try? ensureScriptWrittenToDisk() else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptURL.path, String(pid)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private static func ensureScriptWrittenToDisk() throws -> URL {
        let scriptsDir = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("scripts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: scriptsDir.path) {
            try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        }
        let scriptURL = scriptsDir.appendingPathComponent("watchdog.sh")
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static let source = #"""
    #!/bin/sh
    # Anvil's cleanup watchdog. Spawned as Anvil's direct child so `ps
    # -o ppid= -p $$` reads Anvil's PID at first — the moment Anvil
    # exits for *any* reason, this process gets reparented to launchd
    # (ppid becomes 1), which is how it notices even a crash or kill -9
    # gave it no chance to clean up normally.
    KILL_PID=$1
    while true; do
      PPID_NOW=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
      if [ "$PPID_NOW" = "1" ] || [ -z "$PPID_NOW" ]; then
        kill -9 "$KILL_PID" 2>/dev/null
        exit 0
      fi
      if ! kill -0 "$KILL_PID" 2>/dev/null; then
        exit 0
      fi
      sleep 2
    done
    """#
}

#endif
