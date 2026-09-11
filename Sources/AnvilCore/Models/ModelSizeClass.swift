import Foundation

/// Classifies a model's estimated size relative to this Mac's own RAM,
/// not an absolute cutoff — a 7B model is "Small" on a 128GB Mac Studio
/// and "Large" on a 16GB laptop.
public enum ModelSizeClass: String, CaseIterable, Sendable, Identifiable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Small: up to 25% of RAM (RAM/4). Medium: up to 50%. Large: above
    /// that.
    public static func classify(sizeBytes: Int64, ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelSizeClass {
        let ram = Double(ramBytes)
        let size = Double(sizeBytes)
        if size <= ram / 4 { return .small }
        if size <= ram / 2 { return .medium }
        return .large
    }
}
