import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum MercuryThermalState: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum MercuryContentMode: String, Codable, Sendable, Equatable {
    case unknown
    case screenText
    case screenMixed
    case screenVideo
    case videoCall
}

public struct MercuryRuntimeHealthSnapshot: Codable, Sendable, Equatable {
    public var timestampMillis: UInt64
    public var cpuUsagePercent: Double?
    public var batteryLevelPercent: Double?
    public var isCharging: Bool?
    public var isLowPowerModeEnabled: Bool?
    public var thermalState: MercuryThermalState

    public init(
        timestampMillis: UInt64,
        cpuUsagePercent: Double? = nil,
        batteryLevelPercent: Double? = nil,
        isCharging: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil,
        thermalState: MercuryThermalState = .unknown
    ) {
        self.timestampMillis = timestampMillis
        self.cpuUsagePercent = cpuUsagePercent
        self.batteryLevelPercent = batteryLevelPercent
        self.isCharging = isCharging
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalState = thermalState
    }
}

public struct MercuryRtcStatsSnapshot: Codable, Sendable, Equatable {
    public var timestampMillis: UInt64
    public var codec: MercuryVideoCodec?
    public var wireVersion: MercuryMediaFrameWireVersion
    public var targetBitsPerSecond: Int?
    public var actualBitsPerSecond: Int?
    public var pacerQueueDepth: Int?
    public var decodedFramesPerSecond: Double?
    public var presentTimeErrorMillis: Double?
    public var freezeCount: Int
    public var longTermReferenceRecoveries: Int
    public var fecRecoveredBytes: Int
    public var idrFallbacks: Int
    public var gopLossRate: Double?
    public var roundTripMillis: Int?
    public var packetLossRate: Double?
    public var networkJitterMillis: Double?
    public var contentMode: MercuryContentMode
    public var runtimeHealth: MercuryRuntimeHealthSnapshot?

    public init(
        timestampMillis: UInt64,
        codec: MercuryVideoCodec? = nil,
        wireVersion: MercuryMediaFrameWireVersion = .v1,
        targetBitsPerSecond: Int? = nil,
        actualBitsPerSecond: Int? = nil,
        pacerQueueDepth: Int? = nil,
        decodedFramesPerSecond: Double? = nil,
        presentTimeErrorMillis: Double? = nil,
        freezeCount: Int = 0,
        longTermReferenceRecoveries: Int = 0,
        fecRecoveredBytes: Int = 0,
        idrFallbacks: Int = 0,
        gopLossRate: Double? = nil,
        roundTripMillis: Int? = nil,
        packetLossRate: Double? = nil,
        networkJitterMillis: Double? = nil,
        contentMode: MercuryContentMode = .unknown,
        runtimeHealth: MercuryRuntimeHealthSnapshot? = nil
    ) {
        self.timestampMillis = timestampMillis
        self.codec = codec
        self.wireVersion = wireVersion
        self.targetBitsPerSecond = targetBitsPerSecond
        self.actualBitsPerSecond = actualBitsPerSecond
        self.pacerQueueDepth = pacerQueueDepth
        self.decodedFramesPerSecond = decodedFramesPerSecond
        self.presentTimeErrorMillis = presentTimeErrorMillis
        self.freezeCount = freezeCount
        self.longTermReferenceRecoveries = longTermReferenceRecoveries
        self.fecRecoveredBytes = fecRecoveredBytes
        self.idrFallbacks = idrFallbacks
        self.gopLossRate = gopLossRate
        self.roundTripMillis = roundTripMillis
        self.packetLossRate = packetLossRate
        self.networkJitterMillis = networkJitterMillis
        self.contentMode = contentMode
        self.runtimeHealth = runtimeHealth
    }
}

public struct MercuryImpairmentScenario: Codable, Sendable, Equatable, Hashable {
    public var packetLossPercent: Double
    public var roundTripMillis: Int

    public init(packetLossPercent: Double, roundTripMillis: Int) {
        self.packetLossPercent = packetLossPercent
        self.roundTripMillis = roundTripMillis
    }

    public static let defaultMatrix: [MercuryImpairmentScenario] = [
        MercuryImpairmentScenario(packetLossPercent: 0, roundTripMillis: 30),
        MercuryImpairmentScenario(packetLossPercent: 0, roundTripMillis: 100),
        MercuryImpairmentScenario(packetLossPercent: 0, roundTripMillis: 300),
        MercuryImpairmentScenario(packetLossPercent: 1, roundTripMillis: 30),
        MercuryImpairmentScenario(packetLossPercent: 1, roundTripMillis: 100),
        MercuryImpairmentScenario(packetLossPercent: 1, roundTripMillis: 300),
        MercuryImpairmentScenario(packetLossPercent: 3, roundTripMillis: 30),
        MercuryImpairmentScenario(packetLossPercent: 3, roundTripMillis: 100),
        MercuryImpairmentScenario(packetLossPercent: 3, roundTripMillis: 300),
        MercuryImpairmentScenario(packetLossPercent: 5, roundTripMillis: 30),
        MercuryImpairmentScenario(packetLossPercent: 5, roundTripMillis: 100),
        MercuryImpairmentScenario(packetLossPercent: 5, roundTripMillis: 300),
        MercuryImpairmentScenario(packetLossPercent: 10, roundTripMillis: 30),
        MercuryImpairmentScenario(packetLossPercent: 10, roundTripMillis: 100),
        MercuryImpairmentScenario(packetLossPercent: 10, roundTripMillis: 300)
    ]
}

public enum MercuryRuntimeHealthProbe {
    public static func snapshot(
        timestampMillis: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) -> MercuryRuntimeHealthSnapshot {
        MercuryRuntimeHealthSnapshot(
            timestampMillis: timestampMillis,
            cpuUsagePercent: cpuUsagePercent(),
            batteryLevelPercent: batteryLevelPercent(),
            isCharging: isCharging(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermalState(ProcessInfo.processInfo.thermalState)
        )
    }

    private static func thermalState(_ state: ProcessInfo.ThermalState) -> MercuryThermalState {
        switch state {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }

    private static func cpuUsagePercent() -> Double? {
        #if canImport(Darwin)
        var threads: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threads, &threadCount)
        guard result == KERN_SUCCESS, let threads else { return nil }
        defer {
            let bytes = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), bytes)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(
                        threads[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        $0,
                        &count
                    )
                }
            }
            guard infoResult == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 else {
                continue
            }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }
        return total.isFinite ? total : nil
        #else
        return nil
        #endif
    }

    private static func batteryLevelPercent() -> Double? {
        #if canImport(UIKit)
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        guard device.batteryLevel >= 0 else { return nil }
        return Double(device.batteryLevel) * 100
        #else
        return nil
        #endif
    }

    private static func isCharging() -> Bool? {
        #if canImport(UIKit)
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        switch device.batteryState {
        case .charging, .full:
            return true
        case .unplugged:
            return false
        case .unknown:
            return nil
        @unknown default:
            return nil
        }
        #else
        return nil
        #endif
    }
}
