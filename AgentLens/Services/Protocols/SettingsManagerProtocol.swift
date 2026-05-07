import Foundation
import SwiftUI

// MARK: - SettingsManagerProtocol

/// Protocol defining the settings management interface.
/// This enables dependency injection and testing of settings-related functionality.
///
/// ## Usage
/// ```swift
/// struct MyView {
///     @Bindable var settingsManager: any SettingsManagerProtocol
/// }
/// ```
///
/// For production use, `SettingsManager.shared` conforms to this protocol.
/// For testing, inject a mock implementation.
@MainActor
protocol SettingsManagerProtocol: AnyObject {

    // MARK: - Appearance

    /// Current appearance mode (system, light, dark).
    var appearanceMode: AppearanceMode { get set }

    /// Derived SwiftUI color scheme from appearance mode.
    var preferredSwiftUIColorScheme: ColorScheme? { get }

    // MARK: - Behavior

    /// Refresh interval in seconds for usage aggregation.
    var refreshInterval: TimeInterval { get set }

    /// Whether to show the app in the menu bar.
    var showInMenuBar: Bool { get set }

    /// Whether to launch the app at login.
    var launchAtLogin: Bool { get set }

    /// Default time range for usage display.
    var defaultTimeRange: TimeRange { get set }

    // MARK: - Alerts & Notifications

    /// Optional cost alert threshold in USD.
    var costAlertThreshold: Double? { get set }

    /// Whether daily digest notifications are enabled.
    var dailyDigestEnabled: Bool { get set }

    /// Hour 0-23 for daily digest notification.
    var dailyDigestHour: Int { get set }

    // MARK: - Indexing & Search

    /// Whether conversation indexing is enabled.
    var conversationIndexingEnabled: Bool { get set }

    /// Whether consent for indexing has been shown.
    var conversationIndexingConsentShown: Bool { get set }

    /// Provider for embeddings (deterministic or openai).
    var indexEmbeddingProvider: IndexEmbeddingProviderID { get set }

    /// OpenAI embedding model when provider is .openai.
    var indexOpenAIModel: String { get set }

    // MARK: - Cloud Sync

    /// Whether to sync conversation metadata to Firestore.
    var conversationCloudBackupEnabled: Bool { get set }

    /// Whether to mirror session logs to iCloud.
    var iCloudSessionMirrorEnabled: Bool { get set }

    /// Whether to back up session logs to Firestore.
    var sessionLogCloudBackupEnabled: Bool { get set }

    /// Whether session log backup consent has been shown.
    var sessionLogCloudBackupConsentShown: Bool { get set }

    /// Whether to back up OpenBurnBar Assistant chat message content to Firestore.
    var chatThreadContentCloudBackupEnabled: Bool { get set }

    /// Whether chat content backup consent has been shown.
    var chatThreadContentCloudBackupConsentShown: Bool { get set }

    // MARK: - CLI Assistant

    /// Whether CLI assistant is allowed.
    var cliAssistantAllowed: Bool { get set }

    /// Whether CLI assistant consent has been shown.
    var cliAssistantConsentShown: Bool { get set }

    // MARK: - Controller Runtime

    /// Whether controller runtime is enabled.
    var controllerRuntimeEnabled: Bool { get set }

    /// Controller runtime refresh interval in minutes.
    var controllerRuntimeRefreshMinutes: Int { get set }

    /// Whether local notifications from controller are enabled.
    var controllerLocalNotificationsEnabled: Bool { get set }

    /// Whether Telegram integration is enabled for controller.
    var controllerTelegramEnabled: Bool { get set }

    /// Telegram bot token for controller.
    var controllerTelegramBotToken: String { get set }

    /// Telegram chat ID for controller.
    var controllerTelegramChatID: String { get set }

    /// Whether calendar integration is enabled for controller.
    var controllerCalendarIntegrationEnabled: Bool { get set }

    /// Default calendar hold duration in minutes.
    var controllerCalendarDefaultMinutes: Int { get set }

    /// Default snooze duration in minutes.
    var controllerDefaultSnoozeMinutes: Int { get set }

    /// Whether simulator tools are shown.
    var controllerSimulatorToolsEnabled: Bool { get set }

    // MARK: - Chat Backend

    /// Whether chat backend onboarding is completed.
    var chatBackendOnboardingCompleted: Bool { get set }

    /// Whether the Hermes-specific 1-2-3 setup wizard is completed.
    var hermesSetupWizardCompleted: Bool { get set }

    /// Comma-separated enabled chat backend IDs.
    var enabledChatBackendIDsCSV: String { get set }

    /// OpenClaw gateway base URL.
    var openClawGatewayBaseURL: String { get set }

    /// OpenClaw bearer token.
    var openClawBearerToken: String { get set }

    /// Hermes bearer token.
    var hermesBearerToken: String { get set }

    /// Optional Hermes gateway chat `model` override (see `resolvedHermesChatModel(gatewayAdvertisedModel:)`).
    var hermesChatModelOverride: String { get set }

    /// Hermes gateway base URL. Defaults to the official local web API port.
    var hermesGatewayBaseURL: String { get set }

    /// Whether this Mac may relay local Hermes traffic for signed-in mobile devices.
    var hermesRemoteRelayEnabled: Bool { get set }

    /// Resolves the `model` field for Hermes `POST /v1/chat/completions`.
    func resolvedHermesChatModel(gatewayAdvertisedModel: String?) -> String

    // MARK: - Usage Display

    /// Display mode for usage (currency or tokens).
    var usageDisplayMode: UsageDisplayMode { get set }

    // MARK: - Session Summaries

    /// Whether auto session summaries are enabled.
    var autoSessionSummariesEnabled: Bool { get set }

    /// Summary provider order as comma-separated string.
    var summaryProviderOrderCSV: String { get set }

    /// Summary provider order as array.
    var summaryProviderOrder: [SummaryProviderID] { get }

    /// Daily spend cap in USD for summaries.
    var summaryDailyCapUSD: Double? { get set }

    /// Summary request timeout in seconds.
    var summaryRequestTimeoutSeconds: Double { get set }

    /// Max concurrent summary requests.
    var summaryMaxConcurrency: Int { get set }

    /// Time limit for summary sweep in minutes.
    var summaryTimeLimitMinutes: Int { get set }

    // MARK: - Reranking

    /// Whether cross-encoder reranking is enabled.
    var crossEncoderRerankEnabled: Bool { get set }

    /// Cross-encoder reranking provider.
    var crossEncoderProvider: CrossEncoderProviderID { get set }

    /// Cross-encoder reranking model.
    var crossEncoderModel: String { get set }

    /// Max candidates for reranking.
    var crossEncoderMaxCandidates: Int { get set }

    // MARK: - Provider Settings

    /// MiniMax quota mode.
    var miniMaxQuotaMode: MiniMaxQuotaMode { get set }

    /// Factory quota plan tier.
    var factoryQuotaPlanTier: FactoryQuotaPlanTier { get set }

    /// Whether the smart hub quota display integration is enabled.
    var smartHubQuotaDisplayEnabled: Bool { get set }

    /// Smart hub dashboard URL.
    var smartHubQuotaDashboardURL: String { get set }

    /// Smart hub refresh endpoint URL.
    var smartHubQuotaRefreshURL: String { get set }

    /// Smart hub voice-refresh endpoint URL.
    var smartHubQuotaVoiceRefreshURL: String { get set }

    // MARK: - Artifact Discovery

    /// Whether artifact discovery is enabled.
    var artifactDiscoveryEnabled: Bool { get set }

    /// Registered discovery roots as array.
    var artifactDiscoveryRegisteredRoots: [String] { get set }

    /// Additional known patterns for discovery.
    var artifactDiscoveryAdditionalKnownPatterns: [String] { get set }

    // MARK: - Provider Paths

    /// Log paths per provider.
    var logPaths: [AgentProvider: String] { get set }

    // MARK: - Computed Properties

    /// Refresh interval in minutes.
    var refreshIntervalMinutes: Double { get set }

    /// Preferred embedding version ID (nil means auto).
    var preferredIndexEmbeddingVersionIDValue: String? { get }

    /// Selected onboarding providers.
    var selectedOnboardingProviders: Set<AgentProvider> { get set }

    /// Whether this is the first launch.
    var isFirstLaunch: Bool { get }

    // MARK: - Methods

    /// Format usage metric based on display mode.
    func formatUsageMetric(cost: Double, tokens: Int) -> String

    /// Get enabled chat backends.
    var enabledChatBackends: [ChatBackendID] { get }

    /// Set enabled chat backends.
    func setEnabledChatBackends(_ backends: [ChatBackendID])

    /// Enable or disable a chat backend.
    func setChatBackendEnabled(_ id: ChatBackendID, enabled: Bool)

    /// Set summary provider order.
    func setSummaryProviderOrder(_ order: [SummaryProviderID])

    /// Detect available providers based on log paths.
    func detectAvailableProviders() -> [AgentProvider: Bool]

    /// Check if path exists for provider.
    func pathExists(for provider: AgentProvider) -> Bool

    /// Get resolved path for provider.
    func resolvedPath(for provider: AgentProvider) -> URL?

    /// Reset all paths to defaults.
    func resetPathsToDefaults()
}

// MARK: - SettingsManager Extension

extension SettingsManager: SettingsManagerProtocol {}
