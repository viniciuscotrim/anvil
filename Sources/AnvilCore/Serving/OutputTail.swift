import Foundation

/// Thread-safe rolling buffer of a child process's combined
/// stdout/stderr — fed from a `Pipe`'s `readabilityHandler`, which runs
/// on an arbitrary background queue, not necessarily whatever actor
/// owns the process, so this stays a plain lock-protected class rather
/// than actor-isolated state (matches `ProcessRunner`'s own
/// `OutputCollector`/`CancelFlag` pattern). Kept specifically so a
/// startup failure can report the process's own last few lines of
/// output — often the only thing that actually explains *why* — even
/// when no caller happened to be listening via `onLog`.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let maxCharacters: Int

    init(maxCharacters: Int = 4000) {
        self.maxCharacters = maxCharacters
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        if buffer.count > maxCharacters {
            buffer = String(buffer.suffix(maxCharacters))
        }
    }

    /// The captured tail, trimmed — empty if nothing was ever written.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsAny(_ markers: [String]) -> Bool {
        let current = text.lowercased()
        return markers.contains { current.contains($0.lowercased()) }
    }
}
