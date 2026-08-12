import BurnBarCore
import Darwin
import Foundation

/// Reads the machine status block for a fleet snapshot: CPU percent
/// (`host_statistics`), memory (`vm_statistics64`), load average
/// (`getloadavg`), and free disk (`statfs` on `/`). Thermal and power are
/// reported honestly: on this machine `pmset -g thermlog` is empty, so both
/// sensors are `unavailable(reason)` — values are never invented.
public struct BurnBarFleetMachineStatusProbe: Sendable {
    public init() {}

    /// Builds the machine status block. Numeric fields degrade per-field
    /// (absent, never fabricated); thermal/power are typed sensors.
    public func read() -> BurnBarMachineStatus {
        let cpu = Self.readCPUPercent()
        let (used, total) = Self.readMemory()
        let load = Self.readLoadAverage()
        let diskFree = Self.readDiskFreeBytes()

        return BurnBarMachineStatus(
            cpuPercent: cpu,
            memoryUsedBytes: used,
            memoryTotalBytes: total,
            loadAverage: load,
            diskFreeBytes: diskFree,
            thermal: .unavailable(reason: "pmset thermlog is empty on this machine; no cheap thermal API available"),
            power: .unavailable(reason: "no cheap power-sensor API available on this machine")
        )
    }

    private static func readCPUPercent() -> Double? {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let busy = user + system + nice
        return (busy / total) * 100.0
    }

    private static func readMemory() -> (used: Int?, total: Int) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return (nil, 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count)
        let inactive = UInt64(stats.inactive_count)
        let wire = UInt64(stats.wire_count)
        let free = UInt64(stats.free_count)
        let totalBytes = Int((active + inactive + wire + free) * pageSize)
        let usedBytes = Int((active + inactive + wire) * pageSize)
        return (usedBytes, totalBytes)
    }

    private static func readLoadAverage() -> [Double]? {
        var load = [Double](repeating: 0, count: 3)
        let count = getloadavg(&load, 3)
        guard count == 3 else { return nil }
        return load
    }

    private static func readDiskFreeBytes() -> Int? {
        var fileSystemStats = statfs()
        let result = statfs("/", &fileSystemStats)
        guard result == 0 else { return nil }
        return Int(fileSystemStats.f_bavail) * Int(fileSystemStats.f_bsize)
    }
}
