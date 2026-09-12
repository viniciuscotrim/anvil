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

    /// Sorts a search result's own likely usability on this device ahead
    /// of its size alone — a real, reported problem: a 30GB result
    /// sitting near the top of a phone's search results is "garbage" the
    /// user already knows they'll never run, not just a big download.
    /// 0 = comfortably fits (Small/Medium); 1 = unknown size, or Large
    /// but not literally bigger than this device's RAM (a tight fit,
    /// still worth showing rather than burying); 2 = bigger than this
    /// device's RAM outright — guaranteed to fail to load, not just slow.
    public static func runnabilityRank(
        sizeBytes: Int64?, ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        guard let sizeBytes else { return 1 }
        if Double(sizeBytes) > Double(ramBytes) { return 2 }
        switch classify(sizeBytes: sizeBytes, ramBytes: ramBytes) {
        case .small, .medium: return 0
        case .large: return 1
        }
    }

    /// Stable sort by `runnabilityRank` — results that fit this device
    /// float to the top, ties broken by each result's original relative
    /// order (both catalogs already return results ranked by relevance/
    /// downloads, which this preserves within each rank rather than
    /// reshuffling arbitrarily). `sizeBytes` extracts the byte count to
    /// rank each element by.
    public static func sortedByRunnability<Element>(
        _ elements: [Element], ramBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        sizeBytes: (Element) -> Int64?
    ) -> [Element] {
        elements.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = runnabilityRank(sizeBytes: sizeBytes(lhs.element), ramBytes: ramBytes)
                let rhsRank = runnabilityRank(sizeBytes: sizeBytes(rhs.element), ramBytes: ramBytes)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
