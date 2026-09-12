import Foundation

/// Coordinates the shared unified-memory budget across text and image sessions.
/// Disk size is only a conservative estimate of resident memory; the planner
/// deliberately adds headroom and never treats an unknown size as free.
public final class ResidencyPlanner: @unchecked Sendable {
    public struct Reservation: Equatable, Sendable {
        public let modelID: String
        public let bytes: Int64
    }

    public let budgetBytes: Int64
    private var reservations: [String: Reservation] = [:]
    private var measuredBytes: [String: Int64] = [:]
    private let lock = NSLock()

    public init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        budgetBytes = Int64(Double(physicalMemory) * 0.75)
    }

    public var reservedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return reservations.values.reduce(0) { $0 + $1.bytes }
    }

    public var measuredResidentBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return measuredBytes.values.reduce(0, +)
    }

    public func updateMeasuredResidentBytes(modelID: String, bytes: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        if let bytes { measuredBytes[modelID] = bytes }
        else { measuredBytes.removeValue(forKey: modelID) }
    }

    public func estimate(for model: ModelEntry) -> Int64 {
        let diskBytes = model.sizeBytes ?? 0
        let runtimeOverhead = 512 * 1024 * 1024
        let kvCacheAllowance = model.kind == .text ? 2 * 1024 * 1024 * 1024 : 0
        return max(
            Int64(runtimeOverhead + kvCacheAllowance),
            Int64(Double(diskBytes) * 1.25) + Int64(runtimeOverhead + kvCacheAllowance)
        )
    }

    @discardableResult
    public func reserve(_ model: ModelEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if reservations[model.id] != nil { return true }
        let bytes = estimate(for: model)
        let used = reservations.values.reduce(0) { $0 + $1.bytes }
        guard used <= budgetBytes, bytes <= budgetBytes - used else { return false }
        reservations[model.id] = Reservation(modelID: model.id, bytes: bytes)
        return true
    }

    public func release(modelID: String) {
        lock.lock()
        reservations.removeValue(forKey: modelID)
        measuredBytes.removeValue(forKey: modelID)
        lock.unlock()
    }

    public func reservation(for modelID: String) -> Reservation? {
        lock.lock()
        defer { lock.unlock() }
        return reservations[modelID]
    }
}
