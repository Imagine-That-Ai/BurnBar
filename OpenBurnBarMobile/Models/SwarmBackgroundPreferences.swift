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

public enum MobileBackgroundVisibility: String, CaseIterable, Equatable, Sendable {
    case prominent
    case subtle
    case obscured
    case hidden

    private var restrictionRank: Int {
        switch self {
        case .prominent: return 0
        case .subtle: return 1
        case .obscured: return 2
        case .hidden: return 3
        }
    }

    public func constrained(by inherited: MobileBackgroundVisibility) -> MobileBackgroundVisibility {
        restrictionRank >= inherited.restrictionRank ? self : inherited
    }
}

public struct SwarmBackgroundRenderPlan: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case live
        case staticBackdrop
        case disabledFallback
    }

    public let mode: Mode
    public let maxFrameRate: Double?
    public let particleScale: Double
    public let motionSpeedMultiplierScale: Double
    public let allowsAutoCycling: Bool
    public let allowsSparkles: Bool
    public let isBatteryThrottled: Bool

    public static let prominentLive = SwarmBackgroundRenderPlan(
        mode: .live,
        maxFrameRate: 30,
        particleScale: 1.0,
        motionSpeedMultiplierScale: 1.0,
        allowsAutoCycling: true,
        allowsSparkles: true,
        isBatteryThrottled: false
    )

    public static let subtleLive = SwarmBackgroundRenderPlan(
        mode: .live,
        maxFrameRate: 15,
        particleScale: 0.45,
        motionSpeedMultiplierScale: 0.55,
        allowsAutoCycling: false,
        allowsSparkles: false,
        isBatteryThrottled: true
    )

    public static let staticBackdrop = SwarmBackgroundRenderPlan(
        mode: .staticBackdrop,
        maxFrameRate: nil,
        particleScale: 0,
        motionSpeedMultiplierScale: 0,
        allowsAutoCycling: false,
        allowsSparkles: false,
        isBatteryThrottled: true
    )

    public static let disabledFallback = SwarmBackgroundRenderPlan(
        mode: .disabledFallback,
        maxFrameRate: nil,
        particleScale: 0,
        motionSpeedMultiplierScale: 0,
        allowsAutoCycling: false,
        allowsSparkles: false,
        isBatteryThrottled: false
    )
}

public enum SwarmBackgroundPowerPolicy {
    public static func resolve(
        location: SwarmBackgroundLocation,
        conditionMet: Bool,
        requestedVisibility: MobileBackgroundVisibility,
        scenePhaseActive: Bool,
        isLowPowerModeEnabled: Bool,
        reduceMotion: Bool
    ) -> SwarmBackgroundRenderPlan {
        guard location != .disabled else {
            return .disabledFallback
        }
        guard conditionMet else {
            return .staticBackdrop
        }
        guard scenePhaseActive, requestedVisibility != .hidden else {
            return .staticBackdrop
        }
        guard !reduceMotion, requestedVisibility != .obscured else {
            return .staticBackdrop
        }
        if isLowPowerModeEnabled {
            return requestedVisibility == .prominent ? .subtleLive : .staticBackdrop
        }
        return requestedVisibility == .prominent ? .prominentLive : .subtleLive
    }
}

public enum MobileDecorativeRenderPolicy {
    public static func allowsLiveEffects(
        visibility: MobileBackgroundVisibility,
        scenePhaseActive: Bool
    ) -> Bool {
        scenePhaseActive && visibility != .hidden && visibility != .obscured
    }
}

extension EnvironmentValues {
    @Entry var mobileBackgroundVisibility: MobileBackgroundVisibility = .prominent
    /// True while a Hermes chat reply is actively streaming. The swarm
    /// background reads this to throttle its frame rate so the murmuration
    /// stops competing with streaming text for the same frame budget.
    @Entry var hermesStreamingActive: Bool = false
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
            let isWiFiConnected = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self, isWiFiConnected] in
                self?.isWiFiConnected = isWiFiConnected
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
