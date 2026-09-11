import Foundation

/// A single unit of progress reported while a `Dependency` installs itself.
public struct InstallProgress: Sendable {
    public let message: String
    /// 0...1, or nil when the step's duration is unknown (most installs).
    public let fractionComplete: Double?

    public init(message: String, fractionComplete: Double? = nil) {
        self.message = message
        self.fractionComplete = fractionComplete
    }
}

public enum DependencyError: Error, LocalizedError, Sendable {
    case installFailed(String)
    case unsupportedPlatform(String)

    public var errorDescription: String? {
        switch self {
        case .installFailed(let reason):
            return "Install failed: \(reason)"
        case .unsupportedPlatform(let reason):
            return "Unsupported platform: \(reason)"
        }
    }
}

/// Something the app needs at runtime that may or may not already be present
/// on this machine — a binary, a Python package, a model runtime.
///
/// The contract each conforming type must honor: `check` never has side
/// effects, `install` is silent and non-interactive (no terminal window,
/// no prompt the user has to answer beyond what already happened in the UI),
/// and both are safe to call repeatedly.
public protocol Dependency: Sendable {
    /// Stable identifier used for caching/logging. Not shown to the user.
    var id: String { get }

    /// Shown to the user in status text while this installs.
    var displayName: String { get }

    /// Is this already satisfied on this machine? No side effects.
    func isSatisfied() async -> Bool

    /// Install silently. Must be safe to call even if partially installed
    /// already (idempotent) and must report progress via `onProgress`
    /// rather than printing anywhere.
    func install(onProgress: @escaping @Sendable (InstallProgress) -> Void) async throws
}
