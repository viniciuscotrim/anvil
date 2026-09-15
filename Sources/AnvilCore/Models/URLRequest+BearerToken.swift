import Foundation

extension URLRequest {
    /// Sets `Authorization: Bearer <token>` when a real (non-nil,
    /// non-empty) token is given — a no-op otherwise, so callers can
    /// pass a store's `load()` result straight through without their
    /// own `if let ... !token.isEmpty` check. Used by every Hugging
    /// Face/CivitAI/Draw Things request that authenticates optionally
    /// (private/gated repos, higher rate limits) rather than requiring
    /// a token.
    mutating func setBearerToken(_ token: String?) {
        guard let token, !token.isEmpty else { return }
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
