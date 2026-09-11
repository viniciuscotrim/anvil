import Foundation

public enum ModelError: Error, LocalizedError, Sendable {
    case searchFailed(String)
    case downloadFailed(String)
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .searchFailed(let reason):
            return "Search failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}
