import Foundation
#if canImport(UIKit)
import UIKit
#endif
import OSLog

public enum MobileDiagnosticsCollector {
    private static let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileDiagnosticsCollector")

    public struct Snapshot: Sendable, Codable {
        public let osVersion: String
        public let deviceModel: String
        public let appVersion: String
        public let appBuild: String
        public let batteryLevel: Float
        public let thermalState: String
        public let timestamp: String

        public var asDictionary: [String: Any] {
            [
                "osVersion": osVersion,
                "deviceModel": deviceModel,
                "appVersion": appVersion,
                "appBuild": appBuild,
                "batteryLevel": batteryLevel,
                "thermalState": thermalState,
                "timestamp": timestamp,
            ]
        }
    }

    public static func capture() -> Snapshot {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let model = UIDevice.current.model
        let battery = UIDevice.current.batteryLevel
        #else
        let os = "iOS"
        let model = "iPhone"
        let battery: Float = -1.0
        #endif

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"

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
            deviceModel: model,
            appVersion: version,
            appBuild: build,
            batteryLevel: battery,
            thermalState: thermal,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
