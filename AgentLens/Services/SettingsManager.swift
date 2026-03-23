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

    var dailyDigestEnabled: Bool {
        didSet { save() }
    }

    /// Hour 0–23 local time for daily digest notification.
    var dailyDigestHour: Int {
        didSet { save() }
    }

    /// User opted in to local indexing of conversation text for search and chat context.
    var conversationIndexingEnabled: Bool {
        didSet { save() }
    }

    /// Opt-in: sync conversation metadata (not full transcripts) to Firestore for cross-device recall.
    var conversationCloudBackupEnabled: Bool {
        didSet { save() }
    }

    /// Whether the one-time consent sheet for conversation indexing has been presented.
    var conversationIndexingConsentShown: Bool {
        didSet { save() }
    }

    /// User allowed the app to invoke `claude` / `codex` CLIs for the in-app assistant.
    var cliAssistantAllowed: Bool {
        didSet {
            if cliAssistantAllowed { cliAssistantConsentShown = true }
            save()
        }
    }

    /// Whether the one-time consent sheet for the CLI assistant has been presented.
    var cliAssistantConsentShown: Bool {
        didSet { save() }
    }

    /// Show spend in USD or total token volume (scaled to M/B).
    var usageDisplayMode: UsageDisplayMode {
        didSet { save() }
    }

    // MARK: - Computed
    
    var refreshIntervalMinutes: Double {
        get { refreshInterval / 60 }
        set { refreshInterval = newValue * 60 }
    }
    
    // MARK: - Initialization
    
    private init() {
        BurnBarMigration.migrateUserDefaults()

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

        self.dailyDigestEnabled = defaults.bool(forKey: "dailyDigestEnabled")
        if defaults.object(forKey: "dailyDigestHour") != nil {
            let hour = defaults.integer(forKey: "dailyDigestHour")
            self.dailyDigestHour = (hour >= 0 && hour < 24) ? hour : 18
        } else {
            self.dailyDigestHour = 18
        }

        self.conversationIndexingConsentShown = defaults.bool(forKey: "conversationIndexingConsentShown")
        if defaults.object(forKey: "conversationIndexingEnabled") != nil {
            self.conversationIndexingEnabled = defaults.bool(forKey: "conversationIndexingEnabled")
        } else {
            self.conversationIndexingEnabled = false
        }

        self.conversationCloudBackupEnabled = defaults.bool(forKey: "conversationCloudBackupEnabled")

        self.cliAssistantConsentShown = defaults.bool(forKey: "cliAssistantConsentShown")
        if defaults.object(forKey: "cliAssistantAllowed") != nil {
            self.cliAssistantAllowed = defaults.bool(forKey: "cliAssistantAllowed")
        } else {
            self.cliAssistantAllowed = false
        }

        if let modeRaw = defaults.string(forKey: "usageDisplayMode"),
           let mode = UsageDisplayMode(rawValue: modeRaw) {
            self.usageDisplayMode = mode
        } else {
            self.usageDisplayMode = .currency
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

        defaults.set(dailyDigestEnabled, forKey: "dailyDigestEnabled")
        defaults.set(dailyDigestHour, forKey: "dailyDigestHour")
        defaults.set(conversationIndexingEnabled, forKey: "conversationIndexingEnabled")
        defaults.set(conversationCloudBackupEnabled, forKey: "conversationCloudBackupEnabled")
        defaults.set(conversationIndexingConsentShown, forKey: "conversationIndexingConsentShown")
        defaults.set(cliAssistantAllowed, forKey: "cliAssistantAllowed")
        defaults.set(cliAssistantConsentShown, forKey: "cliAssistantConsentShown")
        defaults.set(usageDisplayMode.rawValue, forKey: "usageDisplayMode")
    }

    /// Formats a usage row or aggregate for the current display preference.
    func formatUsageMetric(cost: Double, tokens: Int) -> String {
        switch usageDisplayMode {
        case .currency: return cost.formatAsCost()
        case .tokens: return tokens.formatAsTokenVolume()
        }
    }
    
    // MARK: - First Launch

    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    }

    // MARK: - Provider Detection

    func detectAvailableProviders() -> [AgentProvider: Bool] {
        var result: [AgentProvider: Bool] = [:]
        let fm = FileManager.default
        for provider in AgentProvider.allCases {
            let path = (provider.logDirectory as NSString).expandingTildeInPath
            result[provider] = fm.fileExists(atPath: path)
        }
        return result
    }

    func pathExists(for provider: AgentProvider) -> Bool {
        let path = logPaths[provider] ?? provider.logDirectory
        let expandedPath = (path as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
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
