import Foundation

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
        didSet { persistence.set(launchAtLogin, forKey: "launchAtLogin") }
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
        if let modeRaw = persistence.optionalString(forKey: "usageDisplayMode"),
           let mode = UsageDisplayMode(rawValue: modeRaw) {
            self.usageDisplayMode = mode
        } else {
            self.usageDisplayMode = .currency
        }
    }
}
