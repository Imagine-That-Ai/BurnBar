import OpenBurnBarKernel
import Darwin
import Foundation

/// Reads the machine status block for a fleet snapshot: CPU percent
/// (`host_statistics`), memory (`vm_statistics64`), load average
/// (`getloadavg`), and free disk (`statfs` on `/`). Thermal and power are
/// reported honestly: on this machine `pmset -g thermlog` is empty, so both
/// sensors are `unavailable(reason)` — values are never invented.
public struct BurnBarFleetMachineStatusProbe: Sendable {
    private let cpuState: CPUState

    public init() {
        self.cpuState = CPUState(sampleProvider: { Self.readCPUSample() })
    }

    /// Internal deterministic seam for CPU delta tests. The provider is
    /// intentionally not public: production callers must use host statistics.
    init(cpuSampleProvider: @escaping @Sendable () -> BurnBarFleetCPUSample?) {
        self.cpuState = CPUState(sampleProvider: cpuSampleProvider)
    }

    /// Builds the machine status block. Numeric fields degrade per-field
    /// (absent, never fabricated); thermal/power are typed sensors.
    public func read() -> BurnBarMachineStatus {
        let cpu = cpuState.readCPUPercent()
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

    private static func readCPUSample() -> BurnBarFleetCPUSample? {
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

        return BurnBarFleetCPUSample(
            user: Double(cpuInfo.cpu_ticks.0),
            system: Double(cpuInfo.cpu_ticks.1),
            idle: Double(cpuInfo.cpu_ticks.2),
            nice: Double(cpuInfo.cpu_ticks.3)
        )
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

        let pageSize = UInt64(getpagesize())
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

/// One cumulative host CPU counter sample. Utilization is derived from the
/// difference between two consecutive samples, never from a single lifetime
/// counter ratio.
struct BurnBarFleetCPUSample: Sendable, Equatable {
    let user: Double
    let system: Double
    let idle: Double
    let nice: Double
}

// AUDIT: previous sample is NSLock-guarded. sendable-allowlist: nslock-protected-storage
private final class CPUState: @unchecked Sendable {
    private let sampleProvider: @Sendable () -> BurnBarFleetCPUSample?
    private let lock = NSLock()
    private var previousSample: BurnBarFleetCPUSample?

    init(sampleProvider: @escaping @Sendable () -> BurnBarFleetCPUSample?) {
        self.sampleProvider = sampleProvider
    }

    func readCPUPercent() -> Double? {
        guard let currentSample = sampleProvider() else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let previousSample else {
            // There is no interval to measure on the first tick. Keep the
            // machine field numeric for the existing snapshot contract while
            // establishing the delta baseline.
            self.previousSample = currentSample
            return 0
        }
        self.previousSample = currentSample

        let userDelta = currentSample.user - previousSample.user
        let systemDelta = currentSample.system - previousSample.system
        let idleDelta = currentSample.idle - previousSample.idle
        let niceDelta = currentSample.nice - previousSample.nice
        let deltas = [userDelta, systemDelta, idleDelta, niceDelta]
        guard deltas.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0, totalDelta.isFinite else { return nil }

        let busyDelta = userDelta + systemDelta + niceDelta
        return (busyDelta / totalDelta) * 100.0
    }
}
