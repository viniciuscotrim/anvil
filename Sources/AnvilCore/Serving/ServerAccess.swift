import Foundation

/// Which network interface a loaded model's server binds to. Local-only
/// is the default for every load — network exposure is something the
/// user opts into explicitly, never automatic.
public enum ServerAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    case localOnly
    case network

    public var id: String { rawValue }

    /// The actual bind address passed to `mlx_lm.server --host`.
    public var host: String {
        switch self {
        case .localOnly: return "127.0.0.1"
        case .network: return "0.0.0.0"
        }
    }

    public var label: String {
        switch self {
        case .localOnly: return "Local only"
        case .network: return "Network"
        }
    }

    public var explanation: String {
        switch self {
        case .localOnly:
            return "Only this Mac can reach it."
        case .network:
            return "Reachable from other devices on your network (e.g. over Tailscale)."
        }
    }
}
