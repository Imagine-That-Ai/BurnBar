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

enum AppearanceMode: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

private enum SettingsSecretDefaultsKey {
    static let controllerTelegramBotToken = "controllerTelegramBotToken"
    static let openClawBearerToken = "openClawBearerToken"
    static let hermesBearerToken = "hermesBearerToken"
}

struct SettingsSecretPersistence {
    let defaults: UserDefaults
    let keychain: KeychainStore

    func load(account: String, legacyDefaultsKey: String) -> String {
        if let stored = try? keychain.string(for: account) {
            if defaults.object(forKey: legacyDefaultsKey) != nil {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return stored
        }

        guard let legacy = defaults.string(forKey: legacyDefaultsKey),
              !legacy.isEmpty else {
            if defaults.object(forKey: legacyDefaultsKey) != nil {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return ""
        }

        do {
            try keychain.set(legacy, for: account)
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }

        return legacy
    }

    func persist(_ value: String, account: String, legacyDefaultsKey: String) {
        do {
            if value.isEmpty {
                try keychain.delete(account: account)
            } else {
                try keychain.set(value, for: account)
            }
            defaults.removeObject(forKey: legacyDefaultsKey)
        } catch {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
    }
}

@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )

    private static let chatGatewaySecrets = KeychainStore(
        service: OpenBurnBarIdentity.chatGatewayKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyChatGatewayKeychainServices
    )
    
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

    var appearanceMode: AppearanceMode {
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

    /// Enables the daemon-owned review/controller loop in the UI.
    var controllerRuntimeEnabled: Bool {
        didSet { save() }
    }

    /// How often AgentLens should refresh the mirrored controller runtime from the daemon.
    var controllerRuntimeRefreshMinutes: Int {
        didSet { save() }
    }

    /// Allow the daemon/controller loop to post local notifications on this Mac.
    var controllerLocalNotificationsEnabled: Bool {
        didSet { save() }
    }

    /// Route unresolved work and nudges through Telegram when configured.
    var controllerTelegramEnabled: Bool {
        didSet { save() }
    }

    /// Telegram bot token for controller notifications/commands.
    var controllerTelegramBotToken: String {
        didSet { save() }
    }

    /// Telegram chat or channel identifier for controller notifications/commands.
    var controllerTelegramChatID: String {
        didSet { save() }
    }

    /// Allow the controller loop to create local calendar placeholders for followups.
    var controllerCalendarIntegrationEnabled: Bool {
        didSet { save() }
    }

    /// Default duration for controller-created calendar holds.
    var controllerCalendarDefaultMinutes: Int {
        didSet { save() }
    }

    /// Default snooze window for followups in minutes.
    var controllerDefaultSnoozeMinutes: Int {
        didSet { save() }
    }

    /// Show simulator / replay tooling in operator-facing surfaces.
    var controllerSimulatorToolsEnabled: Bool {
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

    /// OpenClaw gateway base URL (OpenAI-compatible), e.g. `http://127.0.0.1:18789`.
    var openClawGatewayBaseURL: String {
        didSet { save() }
    }

    /// Optional Bearer token for OpenClaw gateway (empty = omit header).
    var openClawBearerToken: String {
        didSet { save() }
    }

    /// Optional: same string as `API_SERVER_KEY` in ~/.hermes/.env when set; omit when Hermes has no API key.
    var hermesBearerToken: String {
        didSet { save() }
    }

    /// Optional `model` string for `POST /v1/chat/completions` to the Hermes gateway (port 8642).
    /// Empty lets OpenBurnBar pick automatically: if the gateway’s `/v1/models` advertises MiniMax but you use Codex with a ChatGPT account, OpenBurnBar sends a Codex-supported model instead (see `resolvedHermesChatModel(gatewayAdvertisedModel:)`).
    var hermesChatModelOverride: String {
        didSet { save() }
    }

    /// User completed the chat backend picker / health onboarding (first-run or Settings).
    var chatBackendOnboardingCompleted: Bool {
        didSet { save() }
    }

    /// User completed the switcher profile onboarding wizard.
    var switcherOnboardingCompleted: Bool {
        didSet { save() }
    }

    /// Comma-separated `AgentProvider.rawValue` list — providers the user selected during onboarding.
    var selectedOnboardingProvidersCSV: String {
        didSet { save() }
    }

    /// Comma-separated `ChatBackendID.rawValue` list — only these appear in chat UI (subset; order = picker order).
    var enabledChatBackendIDsCSV: String {
        didSet { save() }
    }

    /// Show spend in USD or total token volume (scaled to M/B).
    var usageDisplayMode: UsageDisplayMode {
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

    /// Provider used for cross-encoder reranking.
    var crossEncoderProvider: CrossEncoderProviderID {
        didSet { save() }
    }

    /// Provider-specific model used for cross-encoder reranking.
    var crossEncoderModel: String {
        didSet { save() }
    }

    /// Legacy base URL override retained for settings migration.
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

    /// When enabled and exact token counts are unavailable, attempt tokenizer-assisted
    /// estimation before falling back to character-ratio heuristics. Disabled by default.
    var tokenizerAssistedFallbackEnabled: Bool {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let controllerSecretPersistence: SettingsSecretPersistence
    private let chatGatewaySecretPersistence: SettingsSecretPersistence

    // MARK: - Computed
    
    var refreshIntervalMinutes: Double {
        get { refreshInterval / 60 }
        set { refreshInterval = newValue * 60 }
    }

    var preferredSwiftUIColorScheme: ColorScheme? {
        appearanceMode.colorScheme
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
    
    init(
        defaults: UserDefaults = .standard,
        controllerRuntimeSecrets: KeychainStore = SettingsManager.controllerRuntimeSecrets,
        chatGatewaySecrets: KeychainStore = SettingsManager.chatGatewaySecrets
    ) {
        self.defaults = defaults
        self.controllerSecretPersistence = SettingsSecretPersistence(
            defaults: defaults,
            keychain: controllerRuntimeSecrets
        )
        self.chatGatewaySecretPersistence = SettingsSecretPersistence(
            defaults: defaults,
            keychain: chatGatewaySecrets
        )
        OpenBurnBarMigration.migrateUserDefaults(defaults: defaults)

        // Load from UserDefaults
        
        var loadedLogPaths: [AgentProvider: String] = [:]
        for provider in AgentProvider.allCases {
            let customPath = defaults.string(forKey: "logPath_\(provider.rawValue)")
            loadedLogPaths[provider] = customPath ?? provider.logDirectory
        }
        self.logPaths = loadedLogPaths
        
        let loadedInterval = defaults.double(forKey: "refreshInterval")
        self.refreshInterval = loadedInterval == 0 ? 600 : loadedInterval
        
        let hasLaunched = defaults.bool(forKey: "hasLaunchedBefore")
        self.showInMenuBar = hasLaunched ? defaults.bool(forKey: "showInMenuBar") : true
        
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        if let modeRaw = defaults.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: modeRaw) {
            self.appearanceMode = mode
        } else if defaults.bool(forKey: "preferLightAppearance") {
            self.appearanceMode = .light
        } else {
            self.appearanceMode = .system
        }
        
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
        if defaults.object(forKey: "controllerRuntimeEnabled") != nil {
            self.controllerRuntimeEnabled = defaults.bool(forKey: "controllerRuntimeEnabled")
        } else {
            self.controllerRuntimeEnabled = true
        }
        if defaults.object(forKey: "controllerRuntimeRefreshMinutes") != nil {
            self.controllerRuntimeRefreshMinutes = max(defaults.integer(forKey: "controllerRuntimeRefreshMinutes"), 1)
        } else {
            self.controllerRuntimeRefreshMinutes = 5
        }
        if defaults.object(forKey: "controllerLocalNotificationsEnabled") != nil {
            self.controllerLocalNotificationsEnabled = defaults.bool(forKey: "controllerLocalNotificationsEnabled")
        } else {
            self.controllerLocalNotificationsEnabled = true
        }
        self.controllerTelegramEnabled = defaults.bool(forKey: "controllerTelegramEnabled")
        self.controllerTelegramBotToken = controllerSecretPersistence.load(
            account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.controllerTelegramBotToken
        )
        self.controllerTelegramChatID = defaults.string(forKey: "controllerTelegramChatID") ?? ""
        if defaults.object(forKey: "controllerCalendarIntegrationEnabled") != nil {
            self.controllerCalendarIntegrationEnabled = defaults.bool(forKey: "controllerCalendarIntegrationEnabled")
        } else {
            self.controllerCalendarIntegrationEnabled = true
        }
        if defaults.object(forKey: "controllerCalendarDefaultMinutes") != nil {
            self.controllerCalendarDefaultMinutes = max(defaults.integer(forKey: "controllerCalendarDefaultMinutes"), 15)
        } else {
            self.controllerCalendarDefaultMinutes = 30
        }
        if defaults.object(forKey: "controllerDefaultSnoozeMinutes") != nil {
            self.controllerDefaultSnoozeMinutes = max(defaults.integer(forKey: "controllerDefaultSnoozeMinutes"), 15)
        } else {
            self.controllerDefaultSnoozeMinutes = 180
        }
        self.controllerSimulatorToolsEnabled = defaults.bool(forKey: "controllerSimulatorToolsEnabled")

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

        self.openClawGatewayBaseURL = defaults.string(forKey: "openClawGatewayBaseURL") ?? "http://127.0.0.1:18789"
        self.openClawBearerToken = chatGatewaySecretPersistence.load(
            account: OpenBurnBarIdentity.openClawBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.openClawBearerToken
        )
        self.hermesBearerToken = chatGatewaySecretPersistence.load(
            account: OpenBurnBarIdentity.hermesBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.hermesBearerToken
        )
        self.hermesChatModelOverride = defaults.string(forKey: "hermesChatModelOverride") ?? ""
        self.chatBackendOnboardingCompleted = defaults.bool(forKey: "chatBackendOnboardingCompleted")
        self.switcherOnboardingCompleted = defaults.bool(forKey: "switcherOnboardingCompleted")
        self.selectedOnboardingProvidersCSV = defaults.string(forKey: "selectedOnboardingProvidersCSV") ?? ""

        if defaults.object(forKey: "enabledChatBackendIDsCSV") != nil {
            self.enabledChatBackendIDsCSV = defaults.string(forKey: "enabledChatBackendIDsCSV") ?? ""
        } else {
            if let raw = defaults.string(forKey: "chatBackendID"), let only = ChatBackendID(rawValue: raw) {
                self.enabledChatBackendIDsCSV = ChatBackendID.encodeEnabledList([only])
            } else {
                self.enabledChatBackendIDsCSV = ""
            }
        }

        if let modeRaw = defaults.string(forKey: "usageDisplayMode"),
           let mode = UsageDisplayMode(rawValue: modeRaw) {
            self.usageDisplayMode = mode
        } else {
            self.usageDisplayMode = .currency
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
        let loadedCrossEncoderProvider = defaults.string(forKey: "crossEncoderProvider")
            .flatMap(CrossEncoderProviderID.init(rawValue:))
            ?? .codexCLI
        self.crossEncoderProvider = loadedCrossEncoderProvider
        let loadedCrossEncoderModel = defaults.string(forKey: "crossEncoderModel")
            ?? CrossEncoderCatalog.defaultModel(for: loadedCrossEncoderProvider)
        self.crossEncoderModel = CrossEncoderCatalog.normalizedModel(
            loadedCrossEncoderModel,
            provider: loadedCrossEncoderProvider
        )
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

        // Tokenizer-assisted fallback: default off
        if defaults.object(forKey: "tokenizerAssistedFallbackEnabled") != nil {
            self.tokenizerAssistedFallbackEnabled = defaults.bool(forKey: "tokenizerAssistedFallbackEnabled")
        } else {
            self.tokenizerAssistedFallbackEnabled = false
        }
    }
    
    // MARK: - Persistence
    
    private func save() {
        let defaults = self.defaults
        defaults.set(true, forKey: "hasLaunchedBefore")
        
        for (provider, path) in logPaths {
            defaults.set(path, forKey: "logPath_\(provider.rawValue)")
        }
        
        defaults.set(refreshInterval, forKey: "refreshInterval")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
        defaults.set(defaultTimeRange.rawValue, forKey: "defaultTimeRange")
        
        if let threshold = costAlertThreshold {
            defaults.set(true, forKey: "hasCostAlertThreshold")
            defaults.set(threshold, forKey: "costAlertThreshold")
        } else {
            defaults.set(false, forKey: "hasCostAlertThreshold")
        }

        defaults.set(dailyDigestEnabled, forKey: "dailyDigestEnabled")
        defaults.set(dailyDigestHour, forKey: "dailyDigestHour")
        defaults.set(controllerRuntimeEnabled, forKey: "controllerRuntimeEnabled")
        defaults.set(controllerRuntimeRefreshMinutes, forKey: "controllerRuntimeRefreshMinutes")
        defaults.set(controllerLocalNotificationsEnabled, forKey: "controllerLocalNotificationsEnabled")
        defaults.set(controllerTelegramEnabled, forKey: "controllerTelegramEnabled")
        defaults.set(controllerTelegramChatID, forKey: "controllerTelegramChatID")
        defaults.set(controllerCalendarIntegrationEnabled, forKey: "controllerCalendarIntegrationEnabled")
        defaults.set(controllerCalendarDefaultMinutes, forKey: "controllerCalendarDefaultMinutes")
        defaults.set(controllerDefaultSnoozeMinutes, forKey: "controllerDefaultSnoozeMinutes")
        defaults.set(controllerSimulatorToolsEnabled, forKey: "controllerSimulatorToolsEnabled")
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
        defaults.set(openClawGatewayBaseURL, forKey: "openClawGatewayBaseURL")
        defaults.set(hermesChatModelOverride, forKey: "hermesChatModelOverride")
        defaults.set(chatBackendOnboardingCompleted, forKey: "chatBackendOnboardingCompleted")
        defaults.set(switcherOnboardingCompleted, forKey: "switcherOnboardingCompleted")
        defaults.set(selectedOnboardingProvidersCSV, forKey: "selectedOnboardingProvidersCSV")
        defaults.set(enabledChatBackendIDsCSV, forKey: "enabledChatBackendIDsCSV")
        defaults.set(usageDisplayMode.rawValue, forKey: "usageDisplayMode")

        controllerSecretPersistence.persist(
            controllerTelegramBotToken,
            account: OpenBurnBarIdentity.controllerTelegramBotTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.controllerTelegramBotToken
        )
        chatGatewaySecretPersistence.persist(
            openClawBearerToken,
            account: OpenBurnBarIdentity.openClawBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.openClawBearerToken
        )
        chatGatewaySecretPersistence.persist(
            hermesBearerToken,
            account: OpenBurnBarIdentity.hermesBearerTokenAccount,
            legacyDefaultsKey: SettingsSecretDefaultsKey.hermesBearerToken
        )

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
        defaults.set(crossEncoderProvider.rawValue, forKey: "crossEncoderProvider")
        defaults.set(crossEncoderModel, forKey: "crossEncoderModel")
        defaults.set(crossEncoderBaseURL, forKey: "crossEncoderBaseURL")
        defaults.set(crossEncoderMaxCandidates, forKey: "crossEncoderMaxCandidates")
        defaults.set(crossEncoderMaxCharsPerCandidate, forKey: "crossEncoderMaxCharsPerCandidate")

        defaults.set(miniMaxQuotaMode.rawValue, forKey: "miniMaxQuotaMode")
        defaults.set(factoryQuotaPlanTier.rawValue, forKey: "factoryQuotaPlanTier")
        defaults.set(tokenizerAssistedFallbackEnabled, forKey: "tokenizerAssistedFallbackEnabled")
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

    // MARK: - Chat backends (shown in header)

    var enabledChatBackends: [ChatBackendID] {
        ChatBackendID.decodeEnabledList(fromCSV: enabledChatBackendIDsCSV)
    }

    func setEnabledChatBackends(_ backends: [ChatBackendID]) {
        enabledChatBackendIDsCSV = ChatBackendID.encodeEnabledList(backends)
    }

    func setChatBackendEnabled(_ id: ChatBackendID, enabled: Bool) {
        var list = enabledChatBackends
        if enabled {
            if !list.contains(id) { list.append(id) }
        } else {
            list.removeAll { $0 == id }
        }
        setEnabledChatBackends(list)
    }

    // MARK: - Hermes chat model

    /// Resolves the `model` field for Hermes `POST /v1/chat/completions`. If the gateway’s `/v1/models` lists MiniMax while Codex is backed by a ChatGPT account, upstream rejects that model; we default to a Codex-supported id unless `hermesChatModelOverride` is set.
    static func resolvedHermesChatModel(override: String, gatewayAdvertisedModel: String?) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let advertised = gatewayAdvertisedModel?.trimmingCharacters(in: .whitespacesAndNewlines), !advertised.isEmpty else {
            return "hermes"
        }
        if advertised.range(of: "minimax", options: .caseInsensitive) != nil {
            return CLIBridge.normalizedCodexModel("gpt-5.4-mini")
        }
        return "hermes"
    }

    func resolvedHermesChatModel(gatewayAdvertisedModel: String?) -> String {
        Self.resolvedHermesChatModel(override: hermesChatModelOverride, gatewayAdvertisedModel: gatewayAdvertisedModel)
    }

    // MARK: - Onboarding provider selection

    var selectedOnboardingProviders: Set<AgentProvider> {
        get {
            let csv = selectedOnboardingProvidersCSV
            guard !csv.isEmpty else { return [] }
            return Set(csv.split(separator: ",").compactMap { AgentProvider(rawValue: String($0)) })
        }
        set {
            selectedOnboardingProvidersCSV = newValue.map(\.rawValue).sorted().joined(separator: ",")
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
