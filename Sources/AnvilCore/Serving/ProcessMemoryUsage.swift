import Foundation

#if os(macOS)
import Darwin

public enum ProcessMemoryUsage {
    public static func residentBytes(pid: pid_t) -> Int64? {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<rusage_info_v4>.size,
            alignment: MemoryLayout<rusage_info_v4>.alignment
        )
        defer { buffer.deallocate() }
        let output = buffer.assumingMemoryBound(to: rusage_info_t?.self)
        guard proc_pid_rusage(pid, RUSAGE_INFO_V4, output) == 0 else { return nil }
        return Int64(buffer.load(as: rusage_info_v4.self).ri_resident_size)
    }
}
#endif
