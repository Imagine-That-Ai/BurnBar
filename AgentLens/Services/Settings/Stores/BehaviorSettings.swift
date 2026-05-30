import Foundation
import ServiceManagement

// MARK: - Behavior Settings

@Observable
@MainActor
final class BehaviorSettings {
    private let persistence: SettingsPersistenceCoordinator

    var refreshInterval: TimeInterval = 600 {
        didSet { persistence.set(refreshInterval, forKey: "refreshInterval") }
    }

    var defaultTimeRange: TimeRange = .today {
        didSet { persistence.set(defaultTimeRange, forKey: "defaultTimeRange") }
    }

    var launchAtLogin: Bool = false {
        didSet {
            persistence.set(launchAtLogin, forKey: "launchAtLogin")
            LaunchAtLoginController.apply(enabled: launchAtLogin)
        }
    }

    var usageDisplayMode: UsageDisplayMode = .currency {
        didSet { persistence.set(usageDisplayMode, forKey: "usageDisplayMode") }
    }

    var refreshIntervalMinutes: Double {
        get { refreshInterval / 60 }
        set { refreshInterval = newValue * 60 }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        let loadedInterval = persistence.double(forKey: "refreshInterval")
        self.refreshInterval = loadedInterval == 0 ? 600 : loadedInterval
        if let timeRangeRaw = persistence.optionalString(forKey: "defaultTimeRange"),
           let timeRange = TimeRange(rawValue: timeRangeRaw) {
            self.defaultTimeRange = timeRange
        } else {
            self.defaultTimeRange = .today
        }
        self.launchAtLogin = persistence.bool(forKey: "launchAtLogin")
        LaunchAtLoginController.apply(enabled: launchAtLogin)
        if let modeRaw = persistence.optionalString(forKey: "usageDisplayMode"),
           let mode = UsageDisplayMode(rawValue: modeRaw) {
            self.usageDisplayMode = mode
        } else {
            self.usageDisplayMode = .currency
        }
    }
}

@MainActor
private enum LaunchAtLoginController {
    static func apply(enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("OpenBurnBar launch-at-login update failed: %@", String(describing: error))
        }
    }
}
