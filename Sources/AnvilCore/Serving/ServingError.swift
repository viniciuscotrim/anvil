import Foundation

public enum ServingError: Error, LocalizedError, Sendable {
    case serverFailedToStart(String)
    case serverNotRunning
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serverFailedToStart(let reason):
            return "Could not start the model server: \(reason)"
        case .serverNotRunning:
            return "The model server isn't running"
        case .requestFailed(let reason):
            return "Chat request failed: \(reason)"
        }
    }
}
