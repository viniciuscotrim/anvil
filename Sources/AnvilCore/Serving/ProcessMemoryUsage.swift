import Foundation

#if os(macOS)
import Darwin

public enum ProcessMemoryUsage {
    public static func residentBytes(pid: pid_t) -> Int64? {
        var usage: rusage_info_t?
        guard proc_pid_rusage(pid, RUSAGE_INFO_V4, &usage) == 0,
              let usage else { return nil }
        return Int64(usage.load(as: rusage_info_v4.self).ri_resident_size)
    }
}
#endif
