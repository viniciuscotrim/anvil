import Foundation

/// Defines the backend runtime used to run a model.
public enum InferenceEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case mlx = "mlx"
    case llamaCpp = "llamaCpp"
    case mflux = "mflux"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mlx: return "MLX (Apple Silicon)"
        case .llamaCpp: return "llama.cpp (GGUF)"
        case .mflux: return "mflux (Flux Image)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .mlx: return "MLX"
        case .llamaCpp: return "llama.cpp"
        case .mflux: return "mflux"
        }
    }
}
