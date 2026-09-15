import Foundation
import Observation

/// Drives the check-then-install pattern for the whole app. This is the
/// single choke point every feature goes through before it assumes a
/// dependency is present — call `ensure(_:)` for exactly what that
/// feature needs, when the user actually asks for it. Never call it
/// speculatively for something the user hasn't chosen yet; that's what
/// keeps mflux/mlx-audio uninstalled until image generation or voice
/// is actually used.
@MainActor
@Observable
public final class RequirementsManager {
    public private(set) var statusMessage: String = ""
    public private(set) var isInstalling: Bool = false
    public private(set) var lastError: String?

    @ObservationIgnored
    private var satisfiedCache: Set<String> = []

    public init() {}

    @discardableResult
    public func ensure(_ dependency: some Dependency) async -> Bool {
        if satisfiedCache.contains(dependency.id) { return true }

        if await dependency.isSatisfied() {
            satisfiedCache.insert(dependency.id)
            return true
        }

        isInstalling = true
        lastError = nil
        defer { isInstalling = false }

        do {
            try await dependency.install { [weak self] progress in
                Task { @MainActor in
                    self?.statusMessage = progress.message
                }
            }
            satisfiedCache.insert(dependency.id)
            statusMessage = ""
            return true
        } catch {
            lastError = error.localizedDescription
            statusMessage = ""
            return false
        }
    }
}
