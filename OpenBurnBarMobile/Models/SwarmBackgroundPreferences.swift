import Foundation
import SwiftUI
import Network
import OpenBurnBarCore

public enum SwarmBackgroundLocation: String, Codable, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case agentsTab = "Agents Tab Only"
    case everywhere = "Everywhere"

    public var id: String { rawValue }
}

public enum SwarmBackgroundCondition: String, Codable, CaseIterable, Identifiable {
    case always = "Always"
    case powerConnected = "Power Connected Only"
    case wifiOnly = "Wi-Fi Only"

    public var id: String { rawValue }
}

public struct SwarmBackgroundPreferences: Codable, Equatable {
    public var location: SwarmBackgroundLocation
    public var condition: SwarmBackgroundCondition
    public var selectedGlyphs: [AgentProvider]
    public var isAvatarEnabled: Bool
    public var isBrandTextEnabled: Bool
    public var excludeBrandShapes: Bool

    public init(
        location: SwarmBackgroundLocation = .agentsTab,
        condition: SwarmBackgroundCondition = .always,
        selectedGlyphs: [AgentProvider] = AgentProvider.swarmGlyphProviders,
        isAvatarEnabled: Bool = true,
        isBrandTextEnabled: Bool = true,
        excludeBrandShapes: Bool = false
    ) {
        self.location = location
        self.condition = condition
        self.selectedGlyphs = selectedGlyphs
        self.isAvatarEnabled = isAvatarEnabled
        self.isBrandTextEnabled = isBrandTextEnabled
        self.excludeBrandShapes = excludeBrandShapes
    }

    enum CodingKeys: String, CodingKey {
        case location
        case condition
        case selectedGlyphs
        case isAvatarEnabled
        case isBrandTextEnabled
        case excludeBrandShapes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.location = try container.decodeIfPresent(SwarmBackgroundLocation.self, forKey: .location) ?? .agentsTab
        self.condition = try container.decodeIfPresent(SwarmBackgroundCondition.self, forKey: .condition) ?? .always
        self.selectedGlyphs = try container.decodeIfPresent([AgentProvider].self, forKey: .selectedGlyphs) ?? AgentProvider.swarmGlyphProviders
        self.isAvatarEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAvatarEnabled) ?? true
        self.isBrandTextEnabled = try container.decodeIfPresent(Bool.self, forKey: .isBrandTextEnabled) ?? true
        self.excludeBrandShapes = try container.decodeIfPresent(Bool.self, forKey: .excludeBrandShapes) ?? false
    }

    public static let userDefaultsKey = "swarmBackgroundPreferencesV2"

    public static let defaultJSON: String = {
        let prefs = SwarmBackgroundPreferences()
        guard let data = try? JSONEncoder().encode(prefs),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }()

    public static func from(jsonString: String) -> SwarmBackgroundPreferences {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SwarmBackgroundPreferences.self, from: data) else {
            return SwarmBackgroundPreferences()
        }
        return decoded
    }

    public func toJSONString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return SwarmBackgroundPreferences.defaultJSON
        }
        return json
    }
}

// MARK: - Environment Monitor

/// Global monitor for evaluating "When" conditions (Power, Wi-Fi) on iOS.
@MainActor
public final class SwarmEnvironmentMonitor: ObservableObject {
    public static let shared = SwarmEnvironmentMonitor()

    @Published public private(set) var isPowerConnected: Bool = false
    @Published public private(set) var isWiFiConnected: Bool = false

    private let monitor = NWPathMonitor()

    private init() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryState()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateDidChange),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        #endif

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isWiFiConnected = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
    }

    #if os(iOS)
    @objc private func batteryStateDidChange() {
        updateBatteryState()
    }

    private func updateBatteryState() {
        let state = UIDevice.current.batteryState
        isPowerConnected = (state == .charging || state == .full)
    }
    #endif

    public func meetsCondition(_ condition: SwarmBackgroundCondition) -> Bool {
        switch condition {
        case .always:
            return true
        case .powerConnected:
            return isPowerConnected
        case .wifiOnly:
            return isWiFiConnected
        }
    }
}
