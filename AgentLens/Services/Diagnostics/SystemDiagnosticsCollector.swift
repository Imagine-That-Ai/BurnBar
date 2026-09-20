import Foundation
#if canImport(AppKit)
import AppKit
#endif
import OSLog

/// Gathers non-sensitive macOS system diagnostics, app metadata, and logs for bug reports.
public enum SystemDiagnosticsCollector {
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "SystemDiagnosticsCollector")

    public struct Snapshot: Sendable, Codable {
        public let osVersion: String
        public let macModel: String
        public let appVersion: String
        public let appBuild: String
        public let memoryUsageMB: Double
        public let physicalMemoryGB: Double
        public let thermalState: String
        public let isDaemonConnected: Bool
        public let activeProviders: [String]
        public let timestamp: String

        public var asDictionary: [String: String] {
            [
                "osVersion": osVersion,
                "macModel": macModel,
                "appVersion": appVersion,
                "appBuild": appBuild,
                "memoryUsageMB": String(memoryUsageMB),
                "physicalMemoryGB": String(physicalMemoryGB),
                "thermalState": thermalState,
                "isDaemonConnected": isDaemonConnected ? "true" : "false",
                "activeProviders": activeProviders.joined(separator: ","),
                "timestamp": timestamp
            ]
        }
    }

    /// Captures a point-in-time system and runtime diagnostics snapshot.
    public static func capture(
        isDaemonConnected: Bool = true,
        activeProviders: [String] = []
    ) -> Snapshot {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let macModel = resolveMacModel()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let physMemGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let memUsageMB = currentMemoryUsageMB()

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }

        return Snapshot(
            osVersion: os,
            macModel: macModel,
            appVersion: version,
            appBuild: build,
            memoryUsageMB: (memUsageMB * 10).rounded() / 10,
            physicalMemoryGB: (physMemGB * 10).rounded() / 10,
            thermalState: thermal,
            isDaemonConnected: isDaemonConnected,
            activeProviders: activeProviders,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    private static func resolveMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(cString: model)
        }
        return "Mac"
    }

    private static func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / 1_048_576.0
        }
        return 0.0
    }
}
