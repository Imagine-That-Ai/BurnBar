import Foundation
import SwiftUI

enum SummaryProviderID: String, CaseIterable, Codable {
    case local
    case mlx
    case minimax
    case openrouter
    case zai
}

enum IndexEmbeddingProviderID: String, CaseIterable, Codable {
    case deterministic
    case openai
}

/// Selectable dashboard presentation. `classic` is the shipping `NavigationSplitView` surface;
/// alternates are full-window redesigns the user can opt into from Settings. New alternates append
/// a case here and a branch in `DashboardRootView`; everything else (the picker, persistence) adapts.
enum DashboardLayout: String, CaseIterable, Identifiable {
    case classic
    case alternate3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .alternate3: return "Alternate 3 · Liquid Glass"
        }
    }

    /// One-line description shown beneath the picker.
    var detail: String {
        switch self {
        case .classic:
            return "The original sidebar dashboard with provider and model routes."
        case .alternate3:
            return "A single-canvas Liquid Glass surface — ember warmth layered over glass."
        }
    }

    var symbol: String {
        switch self {
        case .classic: return "sidebar.squares.left"
        case .alternate3: return "circle.hexagongrid.fill"
        }
    }
}

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

    /// Preferred embedding version for semantic indexing/search. Empty string = automatic active version.
    var preferredIndexEmbeddingVersionID: String {
        didSet { save() }
    }

    /// Provider used for new indexing and re-embedding work.
    var indexEmbeddingProvider: IndexEmbeddingProviderID {
        didSet { save() }
    }

    /// OpenAI embedding model used when `indexEmbeddingProvider == .openai`.
    var indexOpenAIModel: String {
        didSet { save() }
    }

    /// Opt-in: sync conversation metadata (not full transcripts) to Firestore for cross-device recall when signed in.
    var conversationCloudBackupEnabled: Bool {
        didSet { save() }
    }

    /// Copy on-disk session files into the app’s iCloud Drive container (independent of Firebase).
    var iCloudSessionMirrorEnabled: Bool {
        didSet { save() }
    }

    /// Opt-in: back up full session-log Markdown to Firestore. Requires auth + `isCloudSyncEnabled`.
    var sessionLogCloudBackupEnabled: Bool {
        didSet { save() }
    }

    /// Whether the one-time cloud session-log backup consent sheet has been shown (per device).
    var sessionLogCloudBackupConsentShown: Bool {
        didSet { save() }
    }

    /// Whether the one-time consent sheet for conversation indexing has been presented.
    var conversationIndexingConsentShown: Bool {
        didSet { save() }
    }

    /// Enables discovery and ingestion of skill/agent source artifacts from registered roots.
    var artifactDiscoveryEnabled: Bool {
        didSet { save() }
    }

    /// JSON string storage for registered discovery roots.
    var artifactDiscoveryRegisteredRootsJSON: String {
        didSet { save() }
    }

    /// JSON string storage for additional basename patterns (supports `*` wildcard).
    var artifactDiscoveryAdditionalKnownPatternsJSON: String {
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

    /// Which dashboard surface the main window renders. Defaults to `.classic`.
    var dashboardLayout: DashboardLayout {
        didSet { save() }
    }

    /// Enables automatic conversation summaries after scan refresh.
    var autoSessionSummariesEnabled: Bool {
        didSet { save() }
    }

    /// Comma-separated provider order, e.g. "local,minimax,openrouter,zai".
    var summaryProviderOrderCSV: String {
        didSet { save() }
    }

    /// Optional hard daily cap for cloud summarization spend (USD). Nil = unlimited.
    var summaryDailyCapUSD: Double? {
        didSet { save() }
    }

    var summaryOpenRouterPrimaryModel: String {
        didSet { save() }
    }

    var summaryOpenRouterFallbackModel: String {
        didSet { save() }
    }

    var summaryMiniMaxModel: String {
        didSet { save() }
    }

    var summaryZaiModel: String {
        didSet { save() }
    }

    var summaryLocalModel: String {
        didSet { save() }
    }

    var summaryLocalBaseURL: String {
        didSet { save() }
    }

    var summaryMLXModel: String {
        didSet { save() }
    }

    var summaryMLXBaseURL: String {
        didSet { save() }
    }

    var summaryMaxPromptChars: Int {
        didSet { save() }
    }

    var summaryMaxOutputTokens: Int {
        didSet { save() }
    }

    var summaryRetryCount: Int {
        didSet { save() }
    }

    var summaryBatchSize: Int {
        didSet { save() }
    }

    var summaryFirstLoadBatchSize: Int {
        didSet { save() }
    }

    /// Persisted once a full initial auto-summary sweep has been attempted at least once.
    var summaryInitialSweepCompleted: Bool {
        didSet { save() }
    }

    var summaryRequestTimeoutSeconds: Double {
        didSet { save() }
    }

    /// Max parallel requests during a sweep (1 = sequential, 8 = default blast).
    var summaryMaxConcurrency: Int {
        didSet { save() }
    }

    /// Hard wall-clock limit per sweep in minutes (0 = no limit).
    var summaryTimeLimitMinutes: Int {
        didSet { save() }
    }

    /// Enables cross-encoder reranking for improved retrieval precision.
    var crossEncoderRerankEnabled: Bool {
        didSet { save() }
    }

    /// Model used for cross-encoder reranking (e.g., gpt-4o-mini, gpt-4o).
    var crossEncoderModel: String {
        didSet { save() }
    }

    /// Base URL for cross-encoder API. Empty = default OpenAI.
    var crossEncoderBaseURL: String {
        didSet { save() }
    }

    /// Maximum number of candidates sent to cross-encoder reranking.
    var crossEncoderMaxCandidates: Int {
        didSet { save() }
    }

    /// Maximum characters per candidate text sent to cross-encoder.
    var crossEncoderMaxCharsPerCandidate: Int {
        didSet { save() }
    }

    var miniMaxQuotaMode: MiniMaxQuotaMode {
        didSet { save() }
    }

    var factoryQuotaPlanTier: FactoryQuotaPlanTier {
        didSet { save() }
    }

    // MARK: - Computed
    
    var refreshIntervalMinutes: Double {
        get { refreshInterval / 60 }
        set { refreshInterval = newValue * 60 }
    }

    var summaryProviderOrder: [SummaryProviderID] {
        let parsed = summaryProviderOrderCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .compactMap(SummaryProviderID.init(rawValue:))
        if parsed.isEmpty {
            return [.local, .mlx, .minimax, .openrouter, .zai]
        }

        var deduped: [SummaryProviderID] = []
        for id in parsed where !deduped.contains(id) {
            deduped.append(id)
        }
        for id in SummaryProviderID.allCases where !deduped.contains(id) {
            deduped.append(id)
        }
        return deduped
    }

    var artifactDiscoveryRegisteredRoots: [String] {
        get { Self.decodeJSONStringArray(artifactDiscoveryRegisteredRootsJSON) }
        set { artifactDiscoveryRegisteredRootsJSON = Self.encodeJSONStringArray(newValue) }
    }

    var artifactDiscoveryAdditionalKnownPatterns: [String] {
        get { Self.decodeJSONStringArray(artifactDiscoveryAdditionalKnownPatternsJSON) }
        set { artifactDiscoveryAdditionalKnownPatternsJSON = Self.encodeJSONStringArray(newValue) }
    }

    var preferredIndexEmbeddingVersionIDValue: String? {
        let trimmed = preferredIndexEmbeddingVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persists provider priority as CSV (see `summaryProviderOrderCSV`).
    func setSummaryProviderOrder(_ order: [SummaryProviderID]) {
        summaryProviderOrderCSV = order.map(\.rawValue).joined(separator: ",")
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
        self.preferredIndexEmbeddingVersionID = defaults.string(forKey: "preferredIndexEmbeddingVersionID") ?? ""
        if
            let rawProvider = defaults.string(forKey: "indexEmbeddingProvider"),
            let provider = IndexEmbeddingProviderID(rawValue: rawProvider)
        {
            self.indexEmbeddingProvider = provider
        } else {
            self.indexEmbeddingProvider = .deterministic
        }
        self.indexOpenAIModel = defaults.string(forKey: "indexOpenAIModel") ?? "text-embedding-3-small"
        if defaults.object(forKey: "artifactDiscoveryEnabled") != nil {
            self.artifactDiscoveryEnabled = defaults.bool(forKey: "artifactDiscoveryEnabled")
        } else {
            self.artifactDiscoveryEnabled = false
        }
        self.artifactDiscoveryRegisteredRootsJSON = defaults.string(forKey: "artifactDiscoveryRegisteredRootsJSON") ?? "[]"
        self.artifactDiscoveryAdditionalKnownPatternsJSON = defaults.string(forKey: "artifactDiscoveryAdditionalKnownPatternsJSON") ?? "[]"

        self.conversationCloudBackupEnabled = defaults.bool(forKey: "conversationCloudBackupEnabled")

        self.iCloudSessionMirrorEnabled = defaults.bool(forKey: "iCloudSessionMirrorEnabled")
        self.sessionLogCloudBackupEnabled = defaults.bool(forKey: "sessionLogCloudBackupEnabled")
        self.sessionLogCloudBackupConsentShown = defaults.bool(forKey: "sessionLogCloudBackupConsentShown")

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

        if let layoutRaw = defaults.string(forKey: "dashboardLayout"),
           let layout = DashboardLayout(rawValue: layoutRaw) {
            self.dashboardLayout = layout
        } else {
            self.dashboardLayout = .classic
        }

        if defaults.object(forKey: "autoSessionSummariesEnabled") != nil {
            self.autoSessionSummariesEnabled = defaults.bool(forKey: "autoSessionSummariesEnabled")
        } else {
            self.autoSessionSummariesEnabled = true
        }
        self.summaryProviderOrderCSV = defaults.string(forKey: "summaryProviderOrderCSV") ?? "local,mlx,minimax,openrouter,zai"
        if defaults.bool(forKey: "hasSummaryDailyCapUSD") {
            self.summaryDailyCapUSD = defaults.double(forKey: "summaryDailyCapUSD")
        } else {
            self.summaryDailyCapUSD = nil
        }
        self.summaryOpenRouterPrimaryModel = defaults.string(forKey: "summaryOpenRouterPrimaryModel") ?? "qwen/qwen3.5-9b"
        self.summaryOpenRouterFallbackModel = defaults.string(forKey: "summaryOpenRouterFallbackModel") ?? "openai/gpt-5-nano"
        self.summaryMiniMaxModel = defaults.string(forKey: "summaryMiniMaxModel") ?? "minimax-m2.7-highspeed"
        self.summaryZaiModel = defaults.string(forKey: "summaryZaiModel") ?? "glm-5-turbo"
        self.summaryLocalModel = defaults.string(forKey: "summaryLocalModel") ?? "qwen3.5:9b"
        self.summaryLocalBaseURL = defaults.string(forKey: "summaryLocalBaseURL") ?? "http://127.0.0.1:11434"
        self.summaryMLXModel = defaults.string(forKey: "summaryMLXModel") ?? "mlx-community/Qwen3-4B-4bit"
        self.summaryMLXBaseURL = defaults.string(forKey: "summaryMLXBaseURL") ?? "http://127.0.0.1:8080"
        if defaults.object(forKey: "summaryMaxPromptChars") != nil {
            self.summaryMaxPromptChars = max(defaults.integer(forKey: "summaryMaxPromptChars"), 4_000)
        } else {
            self.summaryMaxPromptChars = 60_000
        }
        if defaults.object(forKey: "summaryMaxOutputTokens") != nil {
            self.summaryMaxOutputTokens = max(defaults.integer(forKey: "summaryMaxOutputTokens"), 120)
        } else {
            self.summaryMaxOutputTokens = 280
        }
        if defaults.object(forKey: "summaryRetryCount") != nil {
            self.summaryRetryCount = max(defaults.integer(forKey: "summaryRetryCount"), 0)
        } else {
            self.summaryRetryCount = 1
        }
        if defaults.object(forKey: "summaryBatchSize") != nil {
            self.summaryBatchSize = max(defaults.integer(forKey: "summaryBatchSize"), 1)
        } else {
            self.summaryBatchSize = 25
        }
        if defaults.object(forKey: "summaryFirstLoadBatchSize") != nil {
            self.summaryFirstLoadBatchSize = max(defaults.integer(forKey: "summaryFirstLoadBatchSize"), 1)
        } else {
            self.summaryFirstLoadBatchSize = 120
        }
        self.summaryInitialSweepCompleted = defaults.bool(forKey: "summaryInitialSweepCompleted")
        if defaults.object(forKey: "summaryRequestTimeoutSeconds") != nil {
            let timeoutSeconds = defaults.double(forKey: "summaryRequestTimeoutSeconds")
            self.summaryRequestTimeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 20
        } else {
            self.summaryRequestTimeoutSeconds = 20
        }
        if defaults.object(forKey: "summaryMaxConcurrency") != nil {
            self.summaryMaxConcurrency = max(defaults.integer(forKey: "summaryMaxConcurrency"), 1)
        } else {
            self.summaryMaxConcurrency = 8
        }
        if defaults.object(forKey: "summaryTimeLimitMinutes") != nil {
            self.summaryTimeLimitMinutes = max(defaults.integer(forKey: "summaryTimeLimitMinutes"), 0)
        } else {
            self.summaryTimeLimitMinutes = 0
        }

        // Cross-encoder reranking settings (default off for privacy/cost)
        if defaults.object(forKey: "crossEncoderRerankEnabled") != nil {
            self.crossEncoderRerankEnabled = defaults.bool(forKey: "crossEncoderRerankEnabled")
        } else {
            self.crossEncoderRerankEnabled = false
        }
        self.crossEncoderModel = defaults.string(forKey: "crossEncoderModel") ?? "gpt-4o-mini"
        self.crossEncoderBaseURL = defaults.string(forKey: "crossEncoderBaseURL") ?? ""
        if defaults.object(forKey: "crossEncoderMaxCandidates") != nil {
            self.crossEncoderMaxCandidates = max(defaults.integer(forKey: "crossEncoderMaxCandidates"), 5)
        } else {
            self.crossEncoderMaxCandidates = 40
        }
        if defaults.object(forKey: "crossEncoderMaxCharsPerCandidate") != nil {
            self.crossEncoderMaxCharsPerCandidate = max(defaults.integer(forKey: "crossEncoderMaxCharsPerCandidate"), 128)
        } else {
            self.crossEncoderMaxCharsPerCandidate = 512
        }

        if let billingModeRaw = defaults.string(forKey: "miniMaxQuotaMode"),
           let billingMode = MiniMaxQuotaMode(rawValue: billingModeRaw) {
            self.miniMaxQuotaMode = billingMode
        } else {
            self.miniMaxQuotaMode = .tokenPlan
        }

        if let planTierRaw = defaults.string(forKey: "factoryQuotaPlanTier"),
           let planTier = FactoryQuotaPlanTier(rawValue: planTierRaw) {
            self.factoryQuotaPlanTier = planTier
        } else {
            self.factoryQuotaPlanTier = .unknown
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
        defaults.set(preferredIndexEmbeddingVersionID, forKey: "preferredIndexEmbeddingVersionID")
        defaults.set(indexEmbeddingProvider.rawValue, forKey: "indexEmbeddingProvider")
        defaults.set(indexOpenAIModel, forKey: "indexOpenAIModel")
        defaults.set(artifactDiscoveryEnabled, forKey: "artifactDiscoveryEnabled")
        defaults.set(artifactDiscoveryRegisteredRootsJSON, forKey: "artifactDiscoveryRegisteredRootsJSON")
        defaults.set(artifactDiscoveryAdditionalKnownPatternsJSON, forKey: "artifactDiscoveryAdditionalKnownPatternsJSON")
        defaults.set(conversationCloudBackupEnabled, forKey: "conversationCloudBackupEnabled")
        defaults.set(iCloudSessionMirrorEnabled, forKey: "iCloudSessionMirrorEnabled")
        defaults.set(sessionLogCloudBackupEnabled, forKey: "sessionLogCloudBackupEnabled")
        defaults.set(sessionLogCloudBackupConsentShown, forKey: "sessionLogCloudBackupConsentShown")
        defaults.set(conversationIndexingConsentShown, forKey: "conversationIndexingConsentShown")
        defaults.set(cliAssistantAllowed, forKey: "cliAssistantAllowed")
        defaults.set(cliAssistantConsentShown, forKey: "cliAssistantConsentShown")
        defaults.set(usageDisplayMode.rawValue, forKey: "usageDisplayMode")
        defaults.set(dashboardLayout.rawValue, forKey: "dashboardLayout")

        defaults.set(autoSessionSummariesEnabled, forKey: "autoSessionSummariesEnabled")
        defaults.set(summaryProviderOrderCSV, forKey: "summaryProviderOrderCSV")
        if let cap = summaryDailyCapUSD {
            defaults.set(true, forKey: "hasSummaryDailyCapUSD")
            defaults.set(cap, forKey: "summaryDailyCapUSD")
        } else {
            defaults.set(false, forKey: "hasSummaryDailyCapUSD")
        }
        defaults.set(summaryOpenRouterPrimaryModel, forKey: "summaryOpenRouterPrimaryModel")
        defaults.set(summaryOpenRouterFallbackModel, forKey: "summaryOpenRouterFallbackModel")
        defaults.set(summaryMiniMaxModel, forKey: "summaryMiniMaxModel")
        defaults.set(summaryZaiModel, forKey: "summaryZaiModel")
        defaults.set(summaryLocalModel, forKey: "summaryLocalModel")
        defaults.set(summaryLocalBaseURL, forKey: "summaryLocalBaseURL")
        defaults.set(summaryMLXModel, forKey: "summaryMLXModel")
        defaults.set(summaryMLXBaseURL, forKey: "summaryMLXBaseURL")
        defaults.set(summaryMaxPromptChars, forKey: "summaryMaxPromptChars")
        defaults.set(summaryMaxOutputTokens, forKey: "summaryMaxOutputTokens")
        defaults.set(summaryRetryCount, forKey: "summaryRetryCount")
        defaults.set(summaryBatchSize, forKey: "summaryBatchSize")
        defaults.set(summaryFirstLoadBatchSize, forKey: "summaryFirstLoadBatchSize")
        defaults.set(summaryInitialSweepCompleted, forKey: "summaryInitialSweepCompleted")
        defaults.set(summaryRequestTimeoutSeconds, forKey: "summaryRequestTimeoutSeconds")
        defaults.set(summaryMaxConcurrency, forKey: "summaryMaxConcurrency")
        defaults.set(summaryTimeLimitMinutes, forKey: "summaryTimeLimitMinutes")

        // Cross-encoder reranking settings
        defaults.set(crossEncoderRerankEnabled, forKey: "crossEncoderRerankEnabled")
        defaults.set(crossEncoderModel, forKey: "crossEncoderModel")
        defaults.set(crossEncoderBaseURL, forKey: "crossEncoderBaseURL")
        defaults.set(crossEncoderMaxCandidates, forKey: "crossEncoderMaxCandidates")
        defaults.set(crossEncoderMaxCharsPerCandidate, forKey: "crossEncoderMaxCharsPerCandidate")

        defaults.set(miniMaxQuotaMode.rawValue, forKey: "miniMaxQuotaMode")
        defaults.set(factoryQuotaPlanTier.rawValue, forKey: "factoryQuotaPlanTier")
    }

    private static func decodeJSONStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func encodeJSONStringArray(_ values: [String]) -> String {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(normalized),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
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
        for provider in AgentProvider.allCases {
            result[provider] = candidatePaths(for: provider, configuredPath: provider.logDirectory).contains {
                FileManager.default.fileExists(atPath: $0)
            }
        }
        return result
    }

    func pathExists(for provider: AgentProvider) -> Bool {
        let path = logPaths[provider] ?? provider.logDirectory
        return candidatePaths(for: provider, configuredPath: path).contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    // MARK: - Path Resolution

    func resolvedPath(for provider: AgentProvider) -> URL? {
        let path = logPaths[provider] ?? provider.logDirectory
        let expandedPaths = candidatePaths(for: provider, configuredPath: path)
        if let existing = expandedPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: existing)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    
    func resetPathsToDefaults() {
        logPaths = AgentProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = provider.logDirectory
        }
    }

    private func candidatePaths(for provider: AgentProvider, configuredPath: String) -> [String] {
        let expandedConfigured = (configuredPath as NSString).expandingTildeInPath
        var candidates: [String] = []

        switch provider {
        case .augment:
            candidates = [
                expandedConfigured,
                ("~/Library/Application Support/Code/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
                ("~/Library/Application Support/Cursor/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
                ("~/Library/Application Support/Windsurf/User/globalStorage/augment.vscode-augment" as NSString).expandingTildeInPath,
            ]
        case .hermes:
            candidates = [
                expandedConfigured,
                ("~/.hermes" as NSString).expandingTildeInPath,
                ("~/.hermes/sessions" as NSString).expandingTildeInPath,
            ]
        case .goose:
            if let root = ProcessInfo.processInfo.environment["GOOSE_PATH_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !root.isEmpty {
                candidates.append(((root as NSString).appendingPathComponent("data/sessions") as NSString).expandingTildeInPath)
            }
            candidates.append(contentsOf: [
                ("~/Library/Application Support/Block/goose/sessions" as NSString).expandingTildeInPath,
                ("~/.local/share/goose/sessions" as NSString).expandingTildeInPath,
                expandedConfigured,
            ])
        case .forgeDev:
            candidates = [
                expandedConfigured,
                ("~/.forge" as NSString).expandingTildeInPath,
            ]
        default:
            candidates = [expandedConfigured]
        }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
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
