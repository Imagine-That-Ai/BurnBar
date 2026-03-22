import Foundation
import SwiftUI

@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()
    
    // MARK: - Settings
    
    var logPaths: [AgentProvider: String] {
        didSet { save() }
    }
    
    var refreshInterval: TimeInterval {
        didSet { save() }
    }
    
    var showInMenuBar: Bool {
        didSet { save() }
    }
    
    var launchAtLogin: Bool {
        didSet { save() }
    }
    
    var defaultTimeRange: TimeRange {
        didSet { save() }
    }
    
    var costAlertThreshold: Double? {
        didSet { save() }
    }
    
    // MARK: - Computed
    
    var refreshIntervalMinutes: Double {
        get { refreshInterval / 60 }
        set { refreshInterval = newValue * 60 }
    }
    
    // MARK: - Initialization
    
    private init() {
        // Load from UserDefaults
        let defaults = UserDefaults.standard
        
        var loadedLogPaths: [AgentProvider: String] = [:]
        for provider in AgentProvider.allCases {
            let customPath = defaults.string(forKey: "logPath_\(provider.rawValue)")
            loadedLogPaths[provider] = customPath ?? provider.logDirectory
        }
        self.logPaths = loadedLogPaths
        
        let loadedInterval = defaults.double(forKey: "refreshInterval")
        self.refreshInterval = loadedInterval == 0 ? 60 : loadedInterval
        
        let hasLaunched = defaults.bool(forKey: "hasLaunchedBefore")
        self.showInMenuBar = hasLaunched ? defaults.bool(forKey: "showInMenuBar") : true
        
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        
        if let timeRangeRaw = defaults.string(forKey: "defaultTimeRange"),
           let timeRange = TimeRange(rawValue: timeRangeRaw) {
            self.defaultTimeRange = timeRange
        } else {
            self.defaultTimeRange = .today
        }
        
        if defaults.bool(forKey: "hasCostAlertThreshold") {
            self.costAlertThreshold = defaults.double(forKey: "costAlertThreshold")
        } else {
            self.costAlertThreshold = nil
        }
    }
    
    // MARK: - Persistence
    
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "hasLaunchedBefore")
        
        for (provider, path) in logPaths {
            defaults.set(path, forKey: "logPath_\(provider.rawValue)")
        }
        
        defaults.set(refreshInterval, forKey: "refreshInterval")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(defaultTimeRange.rawValue, forKey: "defaultTimeRange")
        
        if let threshold = costAlertThreshold {
            defaults.set(true, forKey: "hasCostAlertThreshold")
            defaults.set(threshold, forKey: "costAlertThreshold")
        } else {
            defaults.set(false, forKey: "hasCostAlertThreshold")
        }
    }
    
    // MARK: - Path Resolution
    
    func resolvedPath(for provider: AgentProvider) -> URL? {
        let path = logPaths[provider] ?? provider.logDirectory
        let expandedPath = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath)
    }
    
    func resetPathsToDefaults() {
        logPaths = AgentProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = provider.logDirectory
        }
    }
}

// MARK: - Time Range

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisMonth = "This Month"
    case allTime = "All Time"
    
    var id: String { rawValue }
    
    var displayName: String { rawValue }
    
    func dateRange() -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return start...end
            
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return start...now
            
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return start...now
            
        case .thisMonth:
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return startOfMonth...now
            
        case .allTime:
            return nil // All time has no range
        }
    }
}
